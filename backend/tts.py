import os
import re
import numpy as np
import onnxruntime as ort
from kokoro_onnx import Kokoro
import asyncio
import json
import inspect
import logging
from concurrent.futures import ThreadPoolExecutor
from typing import AsyncIterator, Iterable, List, Optional
import contextlib
from pathlib import Path
import zipfile

logger = logging.getLogger(__name__)

class TTSEngine:
    def __init__(
        self,
        model_path: str = "models/kokoro-v1.0.onnx",
        voices_path: str = "models/voices-v1.0.bin",
    ):
        # Resolve relative paths against this backend module directory, not the
        # process working directory (important for serverless/ASGI hosts).
        base_dir = Path(__file__).resolve().parent
        mp = Path(model_path)
        if not mp.is_absolute():
            candidate = (base_dir / mp).resolve()
            if candidate.exists():
                model_path = str(candidate)
        vp = Path(voices_path)
        if not vp.is_absolute():
            candidate = (base_dir / vp).resolve()
            if candidate.exists():
                voices_path = str(candidate)

        # Ensure models exist
        if not os.path.exists(model_path):
            raise FileNotFoundError(f"Model not found at {model_path}. Run download_models.py first.")
        
        self.model_path = model_path
        self.voices_path = voices_path

        # Newer kokoro-onnx versions support the v1.0 voices bundle (voices-v1.0.bin).
        # We also keep backward-compatible support for voices.json/voices.npz.
        self._ensure_voices_file()

        self.sample_rate = 24000  # Kokoro default
        self._voices_cache: Optional[List[str]] = None

        # CPU-only mode for maximum compatibility.
        self.providers = ["CPUExecutionProvider"]

        # ONNX Runtime performance tuning (CPU).
        # Keep defaults conservative; allow override via env for deployments.
        sess_options = None
        try:
            sess_options = ort.SessionOptions()
            sess_options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
            # Thread counts: 0 means ORT will choose (often = physical cores).
            intra = int(os.getenv("ORT_INTRA_OP_THREADS", "0") or "0")
            inter = int(os.getenv("ORT_INTER_OP_THREADS", "1") or "1")
            if intra >= 0:
                sess_options.intra_op_num_threads = intra
            if inter >= 0:
                sess_options.inter_op_num_threads = inter
            sess_options.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
            sess_options.add_session_config_entry("session.intra_op.allow_spinning", os.getenv("ORT_ALLOW_SPINNING", "1"))
        except Exception:
            sess_options = None

        # kokoro_onnx API varies by version; try passing providers if supported.
        self._kokoro_sig = inspect.signature(Kokoro)
        self._kokoro_kwargs: dict = {}
        if "providers" in self._kokoro_sig.parameters:
            self._kokoro_kwargs["providers"] = self.providers
        # Newer versions may support passing ORT session options.
        if sess_options is not None:
            for k in ("sess_options", "session_options", "ort_session_options"):
                if k in self._kokoro_sig.parameters:
                    self._kokoro_kwargs[k] = sess_options
                    break

        self.kokoro = self._create_kokoro_instance()

        # Periodic session recycling: after this many sentences the ONNX
        # session is recreated to avoid accumulated internal state that
        # can introduce subtle audio artifacts (crackling / static).
        self._session_recycle_interval = int(
            os.getenv("TTS_SESSION_RECYCLE_SENTENCES", "20")
        )
        self._sentences_since_recycle = 0
        # Future holding a pre-created Kokoro instance for seamless swap.
        self._pending_kokoro: Optional[asyncio.Future] = None

        # Dedicated thread-pool for ONNX inference so synthesis doesn't
        # compete with asyncio I/O tasks on the default executor.
        self._executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="tts")
        # Separate thread-pool for background session creation so it
        # doesn't block ongoing synthesis in _executor.
        self._recycle_executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="tts-recycle")

    def _create_kokoro_instance(self) -> Kokoro:
        """Create a fresh Kokoro instance (rebuilds the ONNX session)."""
        if self._kokoro_kwargs:
            return Kokoro(self.model_path, self.voices_path, **self._kokoro_kwargs)
        return Kokoro(self.model_path, self.voices_path)

    def _maybe_recycle_session(self) -> None:
        """Recreate the ONNX session if the sentence threshold is reached.

        Uses async overlap: starts building the new session in a background
        thread while current synthesis continues using the old session.
        When the new session is ready, swaps it in atomically.
        """
        self._sentences_since_recycle += 1
        if self._sentences_since_recycle >= self._session_recycle_interval:
            if self._pending_kokoro is not None and self._pending_kokoro.done():
                # New session is ready — swap it in.
                try:
                    new_kokoro = self._pending_kokoro.result()
                    self.kokoro = new_kokoro
                    logger.info("Swapped in pre-built ONNX session")
                except Exception as e:
                    logger.warning("Background session creation failed, rebuilding synchronously: %s", e)
                    self.kokoro = self._create_kokoro_instance()
                self._pending_kokoro = None
                self._sentences_since_recycle = 0
            elif self._pending_kokoro is None:
                # Start building new session in background.
                logger.info("Scheduling background ONNX session recycle after %d sentences", self._sentences_since_recycle)
                loop = asyncio.get_event_loop()
                self._pending_kokoro = loop.run_in_executor(
                    self._recycle_executor, self._create_kokoro_instance
                )
                self._sentences_since_recycle = 0
            # else: pending_kokoro is still building — keep using current session

    def list_voices(self) -> List[str]:
        if self._voices_cache is not None:
            return self._voices_cache

        p = Path(self.voices_path)
        voices: List[str] = []
        if p.suffix == ".bin":
            # voices-v1.0.bin is a zip containing <voice_id>.npy entries.
            try:
                with zipfile.ZipFile(str(p), "r") as z:
                    for name in z.namelist():
                        if not name.endswith(".npy"):
                            continue
                        voice_id = name[: -len(".npy")]
                        if voice_id:
                            voices.append(voice_id)
            except zipfile.BadZipFile as e:
                raise ValueError(f"Invalid voices bundle (expected zip): {p}") from e
            voices = sorted(set(voices))
        elif p.suffix == ".npz":
            # np.load returns an NpzFile mapping of arrays.
            with np.load(str(p)) as z:
                voices = sorted(list(z.files))
        elif p.suffix == ".json":
            with p.open("r", encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, dict):
                voices = sorted([str(k) for k in data.keys()])
            elif isinstance(data, list):
                voices = sorted([str(v) for v in data])

        self._voices_cache = voices
        return voices

    def _ensure_voices_file(self) -> None:
        p = Path(self.voices_path)
        if p.exists() and p.suffix in {".bin", ".npz", ".npy", ".json"}:
            return

        # Try common fallbacks in models/.
        candidates = [
            Path("models/voices-v1.0.bin"),
            Path("models/voices.npz"),
            Path("models/voices.json"),
        ]
        for c in candidates:
            if c.exists():
                self.voices_path = str(c)
                return

        raise FileNotFoundError(
            f"Voices file not found. Expected {self.voices_path} or one of: {', '.join(str(c) for c in candidates)}"
        )

    def split_sentences(self, text: str) -> List[str]:
        # Heuristic sentence splitting suited for light novels.
        sentences = re.split(r"(?<!\w\.\w.)(?<![A-Z][a-z]\.)(?<=\.|\?|\!)\s+", text)
        return [s.strip() for s in sentences if s and s.strip()]

    def split_sentences_with_offsets(self, text: str) -> List[tuple[str, int, int]]:
        """Split `text` into sentences and return (sentence, char_start, char_end).

        Offsets are relative to the provided `text` (typically a paragraph).
        The returned span is trimmed for leading/trailing whitespace so clients
        can highlight the exact sentence substring without `indexOf`.
        """
        if not text:
            return []

        # Match the whitespace boundary *after* sentence punctuation.
        boundary = re.compile(r"(?<!\w\.\w.)(?<![A-Z][a-z]\.)(?<=\.|\?|\!)\s+")
        out: List[tuple[str, int, int]] = []
        start = 0
        for m in boundary.finditer(text):
            end = m.start()
            if end <= start:
                start = m.end()
                continue
            seg_start, seg_end = start, end
            # Trim whitespace within the segment and adjust offsets.
            while seg_start < seg_end and text[seg_start].isspace():
                seg_start += 1
            while seg_end > seg_start and text[seg_end - 1].isspace():
                seg_end -= 1
            if seg_end > seg_start:
                out.append((text[seg_start:seg_end], seg_start, seg_end))
            start = m.end()

        # Tail segment.
        if start < len(text):
            seg_start, seg_end = start, len(text)
            while seg_start < seg_end and text[seg_start].isspace():
                seg_start += 1
            while seg_end > seg_start and text[seg_end - 1].isspace():
                seg_end -= 1
            if seg_end > seg_start:
                out.append((text[seg_start:seg_end], seg_start, seg_end))

        # Fallback: if boundary regex didn't match but text has content.
        if not out:
            seg_start, seg_end = 0, len(text)
            while seg_start < seg_end and text[seg_start].isspace():
                seg_start += 1
            while seg_end > seg_start and text[seg_end - 1].isspace():
                seg_end -= 1
            if seg_end > seg_start:
                out.append((text[seg_start:seg_end], seg_start, seg_end))
        return out

    def split_paragraphs(self, paragraphs: List[str]) -> List[tuple[int, int, str, bool]]:
        """Flatten paragraphs into (paragraph_index, sentence_index, sentence_text, is_last_in_paragraph)."""
        out: List[tuple[int, int, str, bool]] = []
        for p_idx, p in enumerate(paragraphs):
            p = (p or "").strip()
            if not p:
                continue
            sentences = self.split_sentences(p)
            if not sentences:
                sentences = [p]
            for s_idx, s in enumerate(sentences):
                out.append((p_idx, s_idx, s, s_idx == (len(sentences) - 1)))
        return out

    def split_paragraphs_with_offsets(self, paragraphs: List[str]) -> List[tuple[int, int, str, bool, int, int]]:
        """Flatten paragraphs into (p_idx, s_idx, sentence, is_last, char_start, char_end)."""
        out: List[tuple[int, int, str, bool, int, int]] = []
        for p_idx, raw in enumerate(paragraphs):
            p = raw or ""
            if not p.strip():
                continue
            parts = self.split_sentences_with_offsets(p)
            if not parts:
                # Whole paragraph as one sentence.
                seg = p
                # Trim offsets to first/last non-space.
                seg_start, seg_end = 0, len(seg)
                while seg_start < seg_end and seg[seg_start].isspace():
                    seg_start += 1
                while seg_end > seg_start and seg[seg_end - 1].isspace():
                    seg_end -= 1
                if seg_end > seg_start:
                    out.append((p_idx, 0, seg[seg_start:seg_end], True, seg_start, seg_end))
                continue

            for s_idx, (s, cs, ce) in enumerate(parts):
                out.append((p_idx, s_idx, s, s_idx == (len(parts) - 1), cs, ce))
        return out

    def _iter_pcm_frames(self, pcm16: bytes, frame_bytes: int) -> Iterable[bytes]:
        if frame_bytes <= 0:
            yield pcm16
            return
        for i in range(0, len(pcm16), frame_bytes):
            yield pcm16[i : i + frame_bytes]

    def _apply_cosine_fade_f32(self, audio: np.ndarray, *, fade_ms: int = 6) -> np.ndarray:
        """Apply a raised-cosine fade-in/out on float32 audio.

        Operates entirely in float32 to avoid quantization round-trips.
        A cosine curve is smoother than linear and eliminates audible clicks
        at sentence boundaries.
        """
        if audio.size < 8 or fade_ms <= 0:
            return audio

        fade_samples = int(self.sample_rate * (float(fade_ms) / 1000.0))
        fade_samples = max(0, min(fade_samples, audio.size // 2))
        if fade_samples < 2:
            return audio

        # Raised-cosine: 0.5 * (1 - cos(pi * t)) for t in [0, 1]
        t = np.linspace(0.0, 1.0, fade_samples, endpoint=False, dtype=np.float32)
        ramp = 0.5 * (1.0 - np.cos(np.pi * t))
        audio = audio.copy()
        audio[:fade_samples] *= ramp
        audio[-fade_samples:] *= ramp[::-1]
        return audio

    @staticmethod
    def _float32_to_pcm16_bytes(audio: np.ndarray) -> bytes:
        """Single float32 -> int16 conversion. Called once at the end of the pipeline."""
        return (np.clip(audio, -1.0, 1.0) * 32767).astype(np.int16).tobytes()

    async def synthesize_sentence_f32(self, sentence: str, voice: str, speed: float) -> np.ndarray:
        """Synthesize a sentence and return float32 audio (no quantization yet)."""
        loop = asyncio.get_running_loop()
        audio, _ = await loop.run_in_executor(
            self._executor, self.kokoro.create, sentence, voice, speed
        )
        self._maybe_recycle_session()
        return np.asarray(audio, dtype=np.float32)

    async def synthesize_sentence_pcm16(self, sentence: str, voice: str, speed: float) -> bytes:
        """Backward-compatible: returns PCM16 bytes."""
        audio = await self.synthesize_sentence_f32(sentence, voice=voice, speed=speed)
        return self._float32_to_pcm16_bytes(audio)

    async def synthesize_sentence_pcm16_smoothed(self, sentence: str, voice: str, speed: float) -> bytes:
        audio = await self.synthesize_sentence_f32(sentence, voice=voice, speed=speed)
        audio = self._apply_cosine_fade_f32(audio)
        return self._float32_to_pcm16_bytes(audio)

    async def generate_audio_stream(
        self,
        text: str,
        voice: str = "af_bella",
        speed: float = 1.0,
        prefetch_sentences: int = 3,
        frame_ms: int = 200,
        cancel_event: Optional[asyncio.Event] = None,
    ) -> AsyncIterator[tuple[str, bytes]]:
        """Yield (sentence_text, pcm16_frame_bytes) in a continuous stream.

        This pre-synthesizes up to `prefetch_sentences` sentences ahead to reduce
        boundary pauses, and yields audio in fixed-duration frames.
        """
        sentences = self.split_sentences(text)
        queue: asyncio.Queue[Optional[tuple[str, bytes]]] = asyncio.Queue(maxsize=max(1, prefetch_sentences))

        frame_samples = int(self.sample_rate * (frame_ms / 1000.0))
        frame_bytes = frame_samples * 2  # int16 mono

        async def producer() -> None:
            try:
                for s in sentences:
                    if cancel_event is not None and cancel_event.is_set():
                        break
                    if not s:
                        continue
                    pcm16 = await self.synthesize_sentence_pcm16(s, voice=voice, speed=speed)
                    await queue.put((s, pcm16))
            finally:
                await queue.put(None)

        producer_task = asyncio.create_task(producer())
        try:
            while True:
                item = await queue.get()
                if item is None:
                    break
                sentence, pcm16 = item
                for frame in self._iter_pcm_frames(pcm16, frame_bytes=frame_bytes):
                    if cancel_event is not None and cancel_event.is_set():
                        return
                    yield (sentence, frame)
        finally:
            producer_task.cancel()
            with contextlib.suppress(BaseException):
                await producer_task

    async def generate_audio_stream_paragraphs(
        self,
        paragraphs: List[str],
        voice: str = "af_bella",
        speed: float = 1.0,
        prefetch_sentences: int = 3,
        frame_ms: int = 200,
        cancel_event: Optional[asyncio.Event] = None,
        *,
        pause_sentence_ms: int = 120,
        pause_period_ms: int = 180,
        pause_exclaim_ms: int = 200,
        pause_question_ms: int = 260,
        pause_paragraph_extra_ms: int = 240,
    ) -> AsyncIterator[tuple[int, int, str, bytes]]:
        """Yield (paragraph_index, sentence_index, sentence_text, pcm16_frame_bytes).

        Adds a small silence pause after each sentence, and a larger one at paragraph boundaries.
        """
        segments = self.split_paragraphs(paragraphs)
        queue: asyncio.Queue[Optional[tuple[int, int, str, bytes, int]]] = asyncio.Queue(
            maxsize=max(1, prefetch_sentences)
        )

        frame_samples = int(self.sample_rate * (frame_ms / 1000.0))
        frame_bytes = frame_samples * 2  # int16 mono

        def pause_ms_for(sentence: str, is_last_in_paragraph: bool) -> int:
            s = sentence.rstrip()
            base = pause_sentence_ms
            if s.endswith('?'):
                base = pause_question_ms
            elif s.endswith('!'):
                base = pause_exclaim_ms
            elif s.endswith('.'):
                base = pause_period_ms
            if is_last_in_paragraph:
                base += pause_paragraph_extra_ms
            return max(0, int(base))

        async def producer() -> None:
            try:
                for p_idx, s_idx, s, is_last in segments:
                    if cancel_event is not None and cancel_event.is_set():
                        break
                    if not s:
                        continue
                    pcm16 = await self.synthesize_sentence_pcm16(s, voice=voice, speed=speed)
                    pause_ms = pause_ms_for(s, is_last)
                    await queue.put((p_idx, s_idx, s, pcm16, pause_ms))
            finally:
                await queue.put(None)

        producer_task = asyncio.create_task(producer())
        try:
            while True:
                item = await queue.get()
                if item is None:
                    break
                p_idx, s_idx, sentence, pcm16, pause_ms = item
                for frame in self._iter_pcm_frames(pcm16, frame_bytes=frame_bytes):
                    if cancel_event is not None and cancel_event.is_set():
                        return
                    yield (p_idx, s_idx, sentence, frame)

                if pause_ms > 0:
                    silence_samples = int(self.sample_rate * (pause_ms / 1000.0))
                    silence_bytes = silence_samples * 2
                    # Chunk silence into normal frames.
                    silence = b"\x00" * silence_bytes
                    for frame in self._iter_pcm_frames(silence, frame_bytes=frame_bytes):
                        if cancel_event is not None and cancel_event.is_set():
                            return
                        yield (p_idx, s_idx, sentence, frame)
        finally:
            producer_task.cancel()
            with contextlib.suppress(BaseException):
                await producer_task

    async def generate_audio_stream_paragraphs_sentence_chunks(
        self,
        paragraphs: List[str],
        voice: str = "af_bella",
        speed: float = 1.0,
        prefetch_sentences: int = 3,
        cancel_event: Optional[asyncio.Event] = None,
        *,
        pause_sentence_ms: int = 120,
        pause_period_ms: int = 180,
        pause_exclaim_ms: int = 200,
        pause_question_ms: int = 260,
        pause_paragraph_extra_ms: int = 240,
        fade_ms: int = 6,
    ) -> AsyncIterator[tuple[int, int, str, bytes, int, int]]:
        """Yield sentence-atomic PCM chunks.

        Returns (paragraph_index, sentence_index, sentence_text, pcm16_bytes).

        Each yielded `pcm16_bytes` contains the full sentence audio (smoothed by
        a short fade-in/out) *plus* a short silence pause appended.

        This is designed so that if buffering is needed, playback can only pause
        between sentences (at the end of the current chunk), not mid-sentence.
        """

        segments = self.split_paragraphs_with_offsets(paragraphs)
        queue: asyncio.Queue[Optional[tuple[int, int, str, bytes, int, int]]] = asyncio.Queue(
            maxsize=max(1, prefetch_sentences)
        )

        def pause_ms_for(sentence: str, is_last_in_paragraph: bool) -> int:
            s = sentence.rstrip()
            base = pause_sentence_ms
            if s.endswith('?'):
                base = pause_question_ms
            elif s.endswith('!'):
                base = pause_exclaim_ms
            elif s.endswith('.'):
                base = pause_period_ms
            if is_last_in_paragraph:
                base += pause_paragraph_extra_ms
            return max(0, int(base))

        async def producer() -> None:
            try:
                for p_idx, s_idx, s, is_last, cs, ce in segments:
                    if cancel_event is not None and cancel_event.is_set():
                        break
                    if not s:
                        continue
                    # Stay in float32 for all processing; convert once at the end.
                    audio_f32 = await self.synthesize_sentence_f32(s, voice=voice, speed=speed)
                    if fade_ms and fade_ms > 0:
                        audio_f32 = self._apply_cosine_fade_f32(audio_f32, fade_ms=int(fade_ms))
                    pause_ms = pause_ms_for(s, is_last)

                    # Append silence in float32 then convert the whole chunk once.
                    if pause_ms > 0:
                        silence_samples = int(self.sample_rate * (pause_ms / 1000.0))
                        silence = np.zeros(silence_samples, dtype=np.float32)
                        audio_f32 = np.concatenate([audio_f32, silence])

                    pcm16 = self._float32_to_pcm16_bytes(audio_f32)
                    await queue.put((p_idx, s_idx, s, pcm16, int(cs), int(ce)))
            finally:
                await queue.put(None)

        producer_task = asyncio.create_task(producer())
        try:
            while True:
                item = await queue.get()
                if item is None:
                    break
                p_idx, s_idx, sentence, pcm16, cs, ce = item
                if cancel_event is not None and cancel_event.is_set():
                    return

                yield (p_idx, s_idx, sentence, pcm16, cs, ce)
        finally:
            producer_task.cancel()
            with contextlib.suppress(BaseException):
                await producer_task

    @staticmethod
    def encode_pcm16_to_flac(pcm16_bytes: bytes, sample_rate: int = 24000) -> bytes:
        """Encode raw PCM16 mono bytes to FLAC (lossless compression).

        Uses soundfile for maximum portability (pip-installable, no external
        binary deps). Falls back to returning the original PCM if soundfile
        is not available.
        """
        try:
            import soundfile as sf
            import io

            samples = np.frombuffer(pcm16_bytes, dtype=np.int16)
            # soundfile expects float or int data; int16 is supported natively.
            buf = io.BytesIO()
            sf.write(buf, samples, sample_rate, format="FLAC", subtype="PCM_16")
            return buf.getvalue()
        except ImportError:
            logger.warning("soundfile not installed; returning raw PCM instead of FLAC")
            return pcm16_bytes

if __name__ == "__main__":
    # Test
    async def test():
        tts = TTSEngine()
        text = "Hello world! This is a test of the automatic text to speech system. It should be fast."
        count = 0
        async for chunk in tts.generate_audio_stream(text):
            count += len(chunk)
            print(f"Generated chunk of size {len(chunk)}")
        print(f"Total bytes: {count}")

    conn = asyncio.run(test())

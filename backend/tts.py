import os
import re
import numpy as np
import onnxruntime as ort
from kokoro_onnx import Kokoro
import asyncio
import json
import inspect
from typing import AsyncIterator, Iterable, List, Optional
import contextlib
from pathlib import Path
import zipfile

class TTSEngine:
    def __init__(
        self,
        model_path: str = "models/kokoro-v1.0.onnx",
        voices_path: str = "models/voices-v1.0.bin",
    ):
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

        # kokoro_onnx API varies by version; try passing providers if supported.
        kokoro_sig = inspect.signature(Kokoro)
        if "providers" in kokoro_sig.parameters:
            self.kokoro = Kokoro(self.model_path, self.voices_path, providers=self.providers)
        else:
            self.kokoro = Kokoro(self.model_path, self.voices_path)

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

    def _iter_pcm_frames(self, pcm16: bytes, frame_bytes: int) -> Iterable[bytes]:
        if frame_bytes <= 0:
            yield pcm16
            return
        for i in range(0, len(pcm16), frame_bytes):
            yield pcm16[i : i + frame_bytes]

    async def synthesize_sentence_pcm16(self, sentence: str, voice: str, speed: float) -> bytes:
        loop = asyncio.get_running_loop()
        audio, _ = await loop.run_in_executor(None, self.kokoro.create, sentence, voice, speed)
        audio_int16 = (np.clip(audio, -1.0, 1.0) * 32767).astype(np.int16)
        return audio_int16.tobytes()

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
            with contextlib.suppress(Exception):
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
            with contextlib.suppress(Exception):
                await producer_task

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

import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException
from fastapi.middleware.cors import CORSMiddleware
import json
import asyncio
import logging
from scraper import NovelCoolScraper
from tts import TTSEngine
import traceback
from contextlib import asynccontextmanager
import time

# Serialize logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup
    try:
        logger.info("Initializing TTS Engine...")
        try:
            import onnxruntime as ort

            logger.info(f"ONNX Runtime providers: {ort.get_available_providers()}")
        except Exception:
            pass
        app.state.tts = TTSEngine()
        logger.info("TTS Engine initialized.")
    except Exception as e:
        logger.error(f"Failed to initialize TTS Engine: {e}")
        app.state.tts = None

    app.state.scraper = NovelCoolScraper()
    app.state.novel_index_cache = {}
    yield
    # Shutdown
    app.state.tts = None
    app.state.scraper = None
    app.state.novel_index_cache = None


app = FastAPI(lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.get("/health")
async def health():
    return {"ok": True, "tts_ready": app.state.tts is not None}


@app.get("/voices")
async def voices():
    if not app.state.tts:
        return {"voices": [], "error": "TTS Engine not initialized"}
    return {"voices": app.state.tts.list_voices()}


@app.get("/novel_index")
async def novel_index(url: str):
    if not url:
        return {"chapters": [], "error": "url is required"}
    chapters = await app.state.scraper.scrape_novel_index(url)
    return {"chapters": chapters}


@app.get("/novel_details")
async def novel_details(url: str):
    if not url:
        return {"title": None, "cover_url": None, "error": "url is required"}
    details = await app.state.scraper.scrape_novel_details(url)
    return details


async def _get_cached_novel_index(novel_url: str):
    """Return cached chapter list for a novel URL, scraping once per TTL."""
    if not novel_url:
        raise HTTPException(status_code=400, detail="url is required")

    cache = app.state.novel_index_cache
    if cache is None:
        cache = {}
        app.state.novel_index_cache = cache

    ttl_s = 30 * 60  # 30 minutes
    now = time.monotonic()
    entry = cache.get(novel_url)
    if entry is not None:
        age = now - float(entry.get("ts", 0.0))
        if age < ttl_s:
            return entry.get("chapters") or []

    chapters = await app.state.scraper.scrape_novel_index(novel_url)
    cache[novel_url] = {"ts": now, "chapters": chapters}
    return chapters


@app.get("/novel_meta")
async def novel_meta(url: str):
    chapters = await _get_cached_novel_index(url)
    max_n = 0
    for c in chapters:
        try:
            n = c.get("n") if isinstance(c, dict) else None
            if isinstance(n, int) and n > max_n:
                max_n = n
        except Exception:
            pass
    return {"count": max_n if max_n > 0 else len(chapters)}


@app.get("/novel_chapter")
async def novel_chapter(url: str, n: int):
    chapters = await _get_cached_novel_index(url)
    # Prefer resolving by parsed chapter number, not list position.
    resolved: dict | None = None
    max_n = 0
    for c in chapters:
        if not isinstance(c, dict):
            continue
        cn = c.get("n")
        if isinstance(cn, int) and cn > max_n:
            max_n = cn
        if isinstance(cn, int) and cn == n:
            resolved = c
            break

    limit = max_n if max_n > 0 else len(chapters)
    if n < 1 or n > limit:
        raise HTTPException(status_code=400, detail=f"chapter n must be between 1 and {limit}")

    if resolved is None:
        # Fallback: old positional behavior.
        item = chapters[n - 1] if (n - 1) < len(chapters) else {}
    else:
        item = resolved
    return {"n": n, "title": item.get("title"), "url": item.get("url")}

@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()
    cancel_event = asyncio.Event()

    try:
        while True:
            data = await websocket.receive_text()
            try:
                message = json.loads(data)
                command = message.get("command")
                
                if command == "scrape":
                    url = message.get("url")
                    if not url:
                        await websocket.send_json({"error": "URL is required"})
                        continue
                        
                    logger.info(f"Scraping URL: {url}")
                    try:
                        result = await app.state.scraper.scrape_chapter(url)
                        await websocket.send_json({"type": "scrape_result", "data": result})
                    except Exception as e:
                         logger.error(f"Scrape error: {e}")
                         await websocket.send_json({"type": "error", "message": str(e)})

                elif command == "tts":
                    text = message.get("text")
                    voice = message.get("voice", "af_bella")
                    speed = message.get("speed", 1.0)
                    
                    if not text:
                        await websocket.send_json({"error": "Text is required"})
                        continue
                        
                    logger.info(f"Streaming TTS for text length: {len(text)}")
                    if not app.state.tts:
                         await websocket.send_json({"error": "TTS Engine not initialized"})
                         continue

                    # Ensure voice is valid for the loaded voice pack.
                    try:
                        available = app.state.tts.list_voices()
                        if available and voice not in available:
                            voice = available[0]
                    except Exception:
                        pass

                    # Stream audio
                    try:
                        async for _, audio_chunk in app.state.tts.generate_audio_stream(
                            text,
                            voice=voice,
                            speed=float(speed),
                            prefetch_sentences=3,
                            frame_ms=200,
                            cancel_event=cancel_event,
                        ):
                            await websocket.send_bytes(audio_chunk)
                        
                        await websocket.send_json({"type": "tts_complete"})
                    except Exception as e:
                        logger.error(f"TTS error: {e}")
                        await websocket.send_json({"type": "error", "message": str(e)})

                elif command == "play":
                    # Single-shot: scrape the chapter, then stream it sentence-by-sentence.
                    url = message.get("url")
                    voice = message.get("voice", "af_bella")
                    speed = float(message.get("speed", 1.0))
                    prefetch = int(message.get("prefetch", 3))
                    frame_ms = int(message.get("frame_ms", 200))
                    start_paragraph = int(message.get("start_paragraph", 0) or 0)
                    realtime = bool(message.get("realtime", True))

                    if not url:
                        await websocket.send_json({"type": "error", "message": "URL is required"})
                        continue
                    if not app.state.tts:
                        await websocket.send_json({"type": "error", "message": "TTS Engine not initialized"})
                        continue

                    cancel_event.clear()
                    paused = False

                    logger.info(f"Play request: url={url} voice={voice} speed={speed}")

                    # Ensure voice is valid for the loaded voice pack.
                    try:
                        available = app.state.tts.list_voices()
                        if available and voice not in available:
                            voice = available[0]
                    except Exception:
                        pass
                    try:
                        chapter = await app.state.scraper.scrape_chapter(url)
                    except Exception as e:
                        await websocket.send_json({"type": "error", "message": str(e)})
                        continue

                    title = chapter.get("title")
                    paragraphs = chapter.get("content") or []

                    if start_paragraph < 0:
                        start_paragraph = 0
                    if start_paragraph > len(paragraphs):
                        start_paragraph = max(0, len(paragraphs) - 1)

                    paragraphs_slice = paragraphs[start_paragraph:] if start_paragraph else paragraphs

                    # Provide total sentence count up-front for download/progress UIs.
                    try:
                        sentence_total = len(app.state.tts.split_paragraphs(paragraphs_slice))
                    except Exception:
                        sentence_total = None
                    await websocket.send_json(
                        {
                            "type": "chapter_info",
                            "title": title,
                            "url": url,
                            "voice": voice,
                            "next_url": chapter.get("next_url"),
                            "prev_url": chapter.get("prev_url"),
                            "paragraphs": paragraphs,
                            "start_paragraph": start_paragraph,
                            "sentence_total": sentence_total,
                            "audio": {
                                "encoding": "pcm_s16le",
                                "sample_rate": app.state.tts.sample_rate,
                                "channels": 1,
                                "frame_ms": frame_ms,
                            },
                        }
                    )

                    last_key = None
                    cumulative_samples = 0
                    sample_rate = app.state.tts.sample_rate
                    try:
                        control_task: asyncio.Task[str] | None = asyncio.create_task(websocket.receive_text())

                        async def handle_control_payload(payload: str) -> None:
                            nonlocal paused
                            try:
                                msg = json.loads(payload)
                            except json.JSONDecodeError:
                                return
                            cmd = msg.get("command")
                            if cmd == "pause":
                                paused = True
                            elif cmd == "resume":
                                paused = False
                            elif cmd == "stop":
                                cancel_event.set()

                        async for p_idx, s_idx, sentence, audio_frame in app.state.tts.generate_audio_stream_paragraphs(
                            paragraphs_slice,
                            voice=voice,
                            speed=speed,
                            prefetch_sentences=prefetch,
                            frame_ms=frame_ms,
                            cancel_event=cancel_event,
                        ):
                            # Consume any pending control messages without concurrent receives.
                            if control_task is not None and control_task.done():
                                try:
                                    await handle_control_payload(control_task.result())
                                except WebSocketDisconnect:
                                    cancel_event.set()
                                control_task = asyncio.create_task(websocket.receive_text())

                            if paused and control_task is not None:
                                control_task.cancel()
                                control_task = None

                            while paused and not cancel_event.is_set():
                                # Block until we get a control message.
                                try:
                                    payload = await websocket.receive_text()
                                except WebSocketDisconnect:
                                    cancel_event.set()
                                    break
                                await handle_control_payload(payload)

                            if not paused and not cancel_event.is_set() and control_task is None:
                                control_task = asyncio.create_task(websocket.receive_text())

                            if cancel_event.is_set():
                                break

                            key = (p_idx + start_paragraph, s_idx, sentence)
                            if key != last_key:
                                last_key = key
                                ms_start = (cumulative_samples * 1000) // sample_rate
                                await websocket.send_json(
                                    {
                                        "type": "sentence",
                                        "text": sentence,
                                        "paragraph_index": int(p_idx + start_paragraph),
                                        "sentence_index": int(s_idx),
                                        "ms_start": ms_start,
                                    }
                                )
                            await websocket.send_bytes(audio_frame)
                            cumulative_samples += len(audio_frame) // 2
                            # No real-time sleep: frames are sent as fast as synthesis
                            # allows. The client fires highlights via ms_start +
                            # getStreamTimeConsumed, so pacing here is not needed.

                        if control_task is not None:
                            control_task.cancel()

                        await websocket.send_json(
                            {
                                "type": "chapter_complete",
                                "next_url": chapter.get("next_url"),
                                "prev_url": chapter.get("prev_url"),
                            }
                        )
                    except Exception as e:
                        logger.error(f"Play stream error: {e}")
                        await websocket.send_json({"type": "error", "message": str(e)})
                
                else:
                    await websocket.send_json({"error": "Unknown command"})
            
            except json.JSONDecodeError:
                await websocket.send_json({"error": "Invalid JSON"})
            except Exception as e:
                logger.error(f"Error processing message: {e}")
                traceback.print_exc()
                await websocket.send_json({"error": "Internal server error"})

    except WebSocketDisconnect:
        logger.info("Client disconnected")
    except Exception as e:
        logger.error(f"WebSocket error: {e}")

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)

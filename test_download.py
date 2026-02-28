#!/usr/bin/env python3
"""Test script to simulate a chapter download via WebSocket and verify FLAC output."""
import asyncio
import json
import sys

async def test_download():
    import websockets
    
    url = "ws://127.0.0.1:8000/ws"
    # Use a short chapter for faster testing
    chapter_url = "https://www.novelcool.com/chapter/Shadow-Slave-Chapter-1/7332078/"
    
    print(f"Connecting to {url}...")
    async with websockets.connect(url, max_size=50 * 1024 * 1024) as ws:
        payload = {
            "command": "play",
            "url": chapter_url,
            "voice": "af_bella",
            "speed": 1.0,
            "prefetch": 3,
            "frame_ms": 200,
            "start_paragraph": 0,
            "realtime": False,
        }
        print(f"Sending play command (realtime=False)...")
        await ws.send(json.dumps(payload))
        
        pcm_total = 0
        sentence_count = 0
        flac_data = None
        got_chapter_complete = False
        
        while True:
            msg = await ws.recv()
            if isinstance(msg, str):
                obj = json.loads(msg)
                t = obj.get("type")
                if t == "chapter_info":
                    title = obj.get("title", "?")
                    st = obj.get("sentence_total")
                    print(f"  chapter_info: title={title}, sentence_total={st}")
                elif t == "sentence":
                    sentence_count += 1
                    text = obj.get("text", "")[:60]
                    if sentence_count <= 3 or sentence_count % 20 == 0:
                        print(f"  sentence #{sentence_count}: {text}...")
                elif t == "flac_data":
                    enc = obj.get("encoding")
                    size = obj.get("size")
                    sr = obj.get("sample_rate")
                    print(f"  flac_data event: encoding={enc}, size={size}, sample_rate={sr}")
                elif t == "chapter_complete":
                    print(f"  chapter_complete received")
                    got_chapter_complete = True
                    break
                elif t == "error":
                    print(f"  ERROR: {obj.get('message')}")
                    break
                else:
                    print(f"  unknown event: {t}")
            else:
                # Binary data
                if flac_data is None and pcm_total > 0:
                    # Check if this might be the FLAC blob (after flac_data event)
                    # Actually, we track via the flac_data event flag
                    pass
                
                # Detect if this binary follows a flac_data event
                # We need to track state more carefully
                pcm_total += len(msg)
                
        # Check: did we get FLAC?
        print(f"\n--- Summary ---")
        print(f"Sentences: {sentence_count}")
        print(f"Total binary received: {pcm_total} bytes")
        print(f"Chapter complete: {got_chapter_complete}")
        
        # Now let's redo with better state tracking for FLAC
        print(f"\nNote: Need to check binary data for FLAC header separately")

async def test_download_v2():
    """Better version that properly tracks flac_data -> binary handoff."""
    import websockets
    
    url = "ws://127.0.0.1:8000/ws"
    chapter_url = "https://www.novelcool.com/chapter/Shadow-Slave-Chapter-1/7332078/"
    
    print(f"\n=== Download Test v2 ===")
    print(f"Connecting to {url}...")
    async with websockets.connect(url, max_size=50 * 1024 * 1024) as ws:
        payload = {
            "command": "play",
            "url": chapter_url,
            "voice": "af_bella",
            "speed": 1.0,
            "prefetch": 3,
            "frame_ms": 200,
            "start_paragraph": 0,
            "realtime": False,
        }
        await ws.send(json.dumps(payload))
        
        pcm_bytes_total = 0
        pcm_chunk_count = 0
        sentence_count = 0
        awaiting_flac = False
        flac_bytes = None
        flac_event = None
        
        while True:
            msg = await ws.recv()
            if isinstance(msg, str):
                obj = json.loads(msg)
                t = obj.get("type")
                if t == "chapter_info":
                    title = obj.get("title", "?")
                    st = obj.get("sentence_total")
                    paras = len(obj.get("paragraphs", []))
                    print(f"  chapter_info: title={title}, sentences={st}, paragraphs={paras}")
                elif t == "sentence":
                    sentence_count += 1
                elif t == "flac_data":
                    flac_event = obj
                    awaiting_flac = True
                    print(f"  flac_data event: {obj}")
                elif t == "chapter_complete":
                    print(f"  chapter_complete")
                    break
                elif t == "error":
                    print(f"  ERROR: {obj.get('message')}")
                    break
            else:
                # Binary
                if awaiting_flac:
                    flac_bytes = msg
                    awaiting_flac = False
                    print(f"  FLAC binary received: {len(msg)} bytes, header={msg[:4]}")
                else:
                    pcm_bytes_total += len(msg)
                    pcm_chunk_count += 1
        
        print(f"\n--- Results ---")
        print(f"Sentences synthesized: {sentence_count}")
        print(f"PCM chunks: {pcm_chunk_count}, total PCM bytes: {pcm_bytes_total}")
        audio_seconds = pcm_bytes_total / 2 / 24000
        print(f"Audio duration (from PCM): {audio_seconds:.1f}s")
        
        if flac_bytes:
            print(f"FLAC received: {len(flac_bytes)} bytes")
            print(f"FLAC header: {flac_bytes[:4]}")
            print(f"FLAC compression ratio: {len(flac_bytes)/max(1,pcm_bytes_total)*100:.1f}%")
            
            # Save FLAC for inspection
            with open("/tmp/test_download.flac", "wb") as f:
                f.write(flac_bytes)
            print(f"Saved to /tmp/test_download.flac")
            
            # Verify with soundfile
            try:
                import soundfile as sf
                info = sf.info("/tmp/test_download.flac")
                print(f"soundfile info: {info.samplerate}Hz, {info.channels}ch, {info.frames} frames, {info.duration:.1f}s")
            except Exception as e:
                print(f"soundfile verify failed: {e}")
        else:
            print("NO FLAC received!")
            # Save last PCM for inspection
            print("(Download completed without FLAC encoding)")

if __name__ == "__main__":
    asyncio.run(test_download_v2())

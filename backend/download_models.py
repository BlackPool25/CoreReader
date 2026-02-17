import os
import requests
import json
import numpy as np

MODEL_URL = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files/kokoro-v0_19.onnx"
VOICES_URL = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files/voices.json"
VOICES_NPZ_PATH = "models/voices.npz"

def download_file(url, path):
    print(f"Downloading {url} to {path}...")
    response = requests.get(url, stream=True)
    if response.status_code == 200:
        with open(path, 'wb') as f:
            for chunk in response.iter_content(chunk_size=8192):
                f.write(chunk)
        print(f"Downloaded {path}")
    else:
        print(f"Failed to download {url}")

if __name__ == "__main__":
    os.makedirs("models", exist_ok=True)
    if not os.path.exists("models/kokoro-v0_19.onnx"):
        download_file(MODEL_URL, "models/kokoro-v0_19.onnx")
    if not os.path.exists("models/voices.json"):
        download_file(VOICES_URL, "models/voices.json")

    # kokoro_onnx expects voices_path to be loadable by np.load (e.g. .npz).
    # Convert the downloaded JSON to a .npz (no pickle) for safe loading.
    if not os.path.exists(VOICES_NPZ_PATH) and os.path.exists("models/voices.json"):
        print("Converting models/voices.json -> models/voices.npz ...")
        with open("models/voices.json", "r", encoding="utf-8") as f:
            voices = json.load(f)
        if not isinstance(voices, dict):
            raise ValueError("voices.json expected to be a dict")
        arrays = {k: np.asarray(v, dtype=np.float32) for k, v in voices.items()}
        np.savez_compressed(VOICES_NPZ_PATH, **arrays)
        print("Wrote models/voices.npz")

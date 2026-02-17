import os
import requests

# Kokoro v1.0 (recommended): larger voice pack.
MODEL_URL = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx"
VOICES_URL = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin"

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
    if not os.path.exists("models/kokoro-v1.0.onnx"):
        download_file(MODEL_URL, "models/kokoro-v1.0.onnx")
    if not os.path.exists("models/voices-v1.0.bin"):
        download_file(VOICES_URL, "models/voices-v1.0.bin")

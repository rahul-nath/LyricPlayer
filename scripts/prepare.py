"""Prepare the two pinned build inputs. Network access requires --download."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ASSETS = {
    "framework.zip": ("https://github.com/ggml-org/whisper.cpp/releases/download/v1.8.4/whisper-v1.8.4-xcframework.zip",
                      "1c7a93bd20fe4e57e0af12051ddb34b7a434dfc9acc02c8313393150b6d1821f"),
    "ggml-base.bin": ("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin",
                      "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--download", action="store_true")
    options = parser.parse_args()
    vendor = ROOT / "Vendor"
    vendor.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(dir=vendor) as temporary:
        stage = Path(temporary)
        for name, (url, digest) in ASSETS.items():
            path = vendor / name
            candidate = path
            if not path.exists():
                if not options.download:
                    parser.exit(1, f"Missing {path}. Supply it or run with --download.\n")
                candidate = stage / name
                subprocess.run(["curl", "-fLSs", "--retry", "2", "-o", candidate, url], check=True)
            with candidate.open("rb") as stream:
                h = hashlib.sha256()
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    h.update(block)
            if h.hexdigest() != digest:
                parser.exit(1, f"Checksum mismatch: {candidate.name}\n")
            if candidate != path:
                candidate.replace(path)
        subprocess.run(["ditto", "-x", "-k", vendor / "framework.zip", stage], check=True)
        extracted = stage / "build-apple/whisper.xcframework"
        if not extracted.is_dir():
            parser.exit(1, "Framework missing from release archive\n")
        dst = vendor / extracted.name
        if dst.exists():
            dst.rename(stage / "previous-framework")
        try:
            extracted.rename(dst)
        except OSError:
            if (stage / "previous-framework").exists():
                (stage / "previous-framework").rename(dst)
            raise
    print("Verified multilingual base model and whisper.cpp v1.8.4 framework.")


if __name__ == "__main__":
    main()

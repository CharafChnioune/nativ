#!/usr/bin/env python3
"""Prepare an explicit host-inference manifest without loading/downloading models."""
import argparse
import hashlib
import json
from pathlib import Path
import wave

ROOT = Path(__file__).resolve().parents[1]


def fixture(path: Path, source: str, target: str) -> dict:
    path = path.expanduser().resolve(strict=True)
    if path.stat().st_size > 2_000_000:
        raise ValueError("Use a synthetic WAV fixture under 2 MB.")
    with wave.open(str(path), "rb") as audio:
        if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate(), audio.getcomptype()) != (1, 2, 16000, "NONE"):
            raise ValueError("Fixtures must be mono 16 kHz PCM16 WAV.")
        if not 0 < audio.getnframes() <= 16000 * 12:
            raise ValueError("Fixtures must contain at most twelve seconds of input.")
    return {"source": source, "target": target, "directory": str(path.parent), "synthetic": True,
            "artifact": {"filename": path.name, "size": path.stat().st_size,
                         "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-cache", type=Path, required=True)
    parser.add_argument("--mlx-executable", type=Path, required=True)
    parser.add_argument("--llama-executable", type=Path, required=True)
    parser.add_argument("--omni-directory", type=Path, required=True)
    parser.add_argument("--nl-synthetic-fixture", type=Path, required=True)
    parser.add_argument("--en-synthetic-fixture", type=Path, required=True)
    parser.add_argument("--recognition-profile", default="whisper-large-v3-turbo")
    parser.add_argument("--translation-profile", default="gemma-4-e4b-it-4bit")
    parser.add_argument("--omni-precision", choices=["Q8_0", "Q4_K_M"], default="Q8_0")
    parser.add_argument("--strategy", choices=["sequential", "resident"], default="sequential")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    models = json.loads((ROOT / "ThirdParty/TranslationCascade/model-manifest.json").read_text())
    omni = json.loads((ROOT / "ThirdParty/LFMRealtime/runtime-manifest.json").read_text())["model"]["artifacts"]

    def model(name: str) -> dict:
        pin = models[name]
        return {"modelID": pin["repository"], "revision": pin["revision"], "artifacts": pin["artifacts"]}

    data = {"modelSearchPath": str(args.model_cache.expanduser().resolve(strict=True)),
            "mlxExecutable": str(args.mlx_executable.expanduser().resolve(strict=True)),
            "strategy": args.strategy, "recognition": model(args.recognition_profile),
            "translation": model(args.translation_profile),
            "omni": {"executable": str(args.llama_executable.expanduser().resolve(strict=True)),
                     "directory": str(args.omni_directory.expanduser().resolve(strict=True)),
                     "model": omni[args.omni_precision], "projector": omni["projector"]},
            "fixtures": [fixture(args.nl_synthetic_fixture, "nl", "en"), fixture(args.en_synthetic_fixture, "en", "nl")]}
    # Never replace an earlier experiment's evidence. Choose a distinct output
    # when changing pins, fixtures, precision or residency strategy.
    with args.output.expanduser().open("x", encoding="utf-8") as output:
        json.dump(data, output, indent=2)
        output.write("\n")
    print(f"Prepared {args.output}; no inference, model download, or quality qualification was performed.")


if __name__ == "__main__":
    main()

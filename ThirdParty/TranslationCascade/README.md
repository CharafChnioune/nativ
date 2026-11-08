# Local cascade artifacts

`model-manifest.json` records the exact snapshots actually downloaded into the development build directory, with verified byte counts and SHA-256 digests. Model weights are not bundled in this repository or the application. These are experimental candidates, not qualified defaults.

| Component | Repository | Revision | Declared license |
| --- | --- | --- | --- |
| Recognition | `mlx-community/whisper-large-v3-turbo` | `a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb` | MIT |
| Translation candidate | `mlx-community/gemma-4-e4b-it-4bit` | `475b9088d29754a3379866cf5aeb6b41acd313c2` | `gemma` in this conversion's pinned card |
| Explicit smaller experiment | `mlx-community/gemma-4-e2b-it-4bit` | `238767527555cb75a05732a84dff5d6ba0dd6809` | `gemma` in this conversion's pinned card |
| Whisper processor | `openai/whisper-large-v3-turbo` | `41f01f3fe87f28c78e2fbf8b568835947dd65ed9` | MIT |

The pinned MLX Whisper snapshot contains only weights and configuration. MLX Audio 0.6.4 also requires the OpenAI processor files. `whisper-processor-manifest.json` pins all nine auxiliary artifacts. The explicit **Prepare Whisper tokenizer** action verifies the installed source weights/configuration and downloads these small files into Nativ's own preparation directory; it does not replace the original snapshot. Compiled pins in `TranslationWhisperPreparation.swift` are the execution authority. The MIT notice is preserved in `licenses/LICENSE-Whisper-MIT`.

The Gemma conversion card declares `gemma`, whereas the current Google base card displays a different license identifier. That discrepancy is not silently resolved in favor of a more permissive license. Confirm terms applicable to the exact pinned conversion and its source revision before redistributing weights. The E4B conversion names source revision `fee6332c1abaafb77f6f9624236c63aa2f1d0187`.

Optional Chatterbox candidates were inspected, but their weights were not downloaded or qualified in this run:

- `mlx-community/chatterbox-multilingual-v3@03565773edd72e949572557597af8063bb49a18a`, model-card license MIT.
- Its separate `mlx-community/S3TokenizerV2@e0c9886f0e1c35ae85b1f27277416fb19fc72bec` dependency must also be installed in the normal Hugging Face cache.
- Multilingual preparation requires `Cangjie5_TC.json` and a readable reference recording the user has permission to use. No dummy or stock reference is inserted.

See `Docs/development/translation-cascade.md` for measured failures, adapter limits, and reproducible tests. LFM3 artifacts and licenses are separately pinned under `ThirdParty/LFMRealtime`.

Sources: [pinned E4B card](https://huggingface.co/mlx-community/gemma-4-e4b-it-4bit/blob/475b9088d29754a3379866cf5aeb6b41acd313c2/README.md), [Whisper](https://github.com/openai/whisper), [Chatterbox multilingual card](https://huggingface.co/mlx-community/chatterbox-multilingual-v3).

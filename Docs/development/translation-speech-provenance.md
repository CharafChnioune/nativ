# Stock conditioning and speech-asset provenance

## Chatterbox needs an actual reference in the pinned profile

The bundled MLX Audio adapter loads optional `conds.safetensors` in `post_load_hook`. Its `generate` path uses supplied reference audio first, then precomputed conditionals; otherwise it fails. The pinned [`mlx-community/chatterbox-multilingual-v3` snapshot](https://huggingface.co/mlx-community/chatterbox-multilingual-v3/tree/03565773edd72e949572557597af8063bb49a18a) contains no `conds.safetensors`. A generic upstream demo that omits a reference is not evidence that this conversion supplies a stock voice. Source inspection is recorded against the [pinned bundled adapter](https://github.com/Neywa-Labs/mlx-audio/blob/ecd43b9f5af55982f4e1bd810d7b60cbc3dfae23/mlx_audio/tts/models/chatterbox/chatterbox.py); no model was loaded for this inspection.

`TranslationStockVoicePreparation` therefore provides an explicit, optional **Thorsten · German recording · CC0** preparation action. It does not select Chatterbox, replace LFM3, choose Apple speech, or start inference. Session startup only accepts an already prepared reference or another explicitly chosen recording.

## Exact stock source

The recording author is Thorsten Müller. His [project website](https://www.thorsten-voice.de/en/) explains that he deliberately released his own voice for open offline TTS, including commercial use. The [pinned project license](https://github.com/thorstenMueller/Thorsten-Voice/blob/29d0c153c55d8ffaa0ebf8ed1ecc879bff9fdf27/LICENSE) is CC0-1.0. The pinned [audio comparison document](https://github.com/thorstenMueller/Thorsten-Voice/blob/29d0c153c55d8ffaa0ebf8ed1ecc879bff9fdf27/docs/audio_compare.md) identifies the selected `*-gt.wav` files as original dataset recordings, distinguishing them from synthesized comparison samples.

Repository: `thorstenMueller/Thorsten-Voice`, revision `29d0c153c55d8ffaa0ebf8ed1ecc879bff9fdf27`.

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `docs/samples/sample03-gt.wav` | 217858 | `1892697190fe190f41037a1c5ac4e02b60d6f4a490408ab3b1b88a490b3b6750` |
| `docs/samples/sample01-gt.wav` | 113782 | `09fb12ff218399a4e4eab6c592eb36bbe4743db9ce5249742129bc3add734ca1` |
| `LICENSE` | 6555 | `36ffd9dc085d529a7e60e1276d73ae5a030b020313e6c5408593a6ae2af39673` |
| Derived `thorsten-stock-de.wav` | 330792 | `38cad5dc655d2749fab0a785c11848c0d72607c4bce07bec6fcbfaa3dab19f59` |

Preparation concatenates the original PCM from sample 03 and sample 01, in that order, and writes a standard WAV header. It applies no resynthesis, gain change or resampling. The result is 7.49995465 seconds of mono PCM16 at 22,050 Hz. Each input, the CC0 license, and the derived output are size/hash verified. The complete directory is staged before installation and retains the source clips, license and attribution notice. No reference download occurs when merely opening Translate. The data transfer is approximately 338 KB; it downloads no model weights.

The source language is **German**. Cross-language conditioning may affect accent and prosody. This reference's naturalness, expressiveness and NL/EN fidelity are not qualified, and it is not an accepted main voice. A visible preparation action selects the reference only when the user chooses it. The existence of a license is separate from any quality or language claim.

## S3TokenizerV2 license boundary

The exact [`mlx-community/S3TokenizerV2` revision](https://huggingface.co/mlx-community/S3TokenizerV2/tree/e0c9886f0e1c35ae85b1f27277416fb19fc72bec) has four files: `.gitattributes`, `README.md`, `config.json`, and `model.safetensors`. Its [README](https://huggingface.co/mlx-community/S3TokenizerV2/blob/e0c9886f0e1c35ae85b1f27277416fb19fc72bec/README.md) explicitly identifies it as an MLX conversion of `FunAudioLLM/CosyVoice2-0.5B`. At this revision there is **no license field, LICENSE file or NOTICE file for the conversion**.

The official [CosyVoice2-0.5B model card at `eec1ae6c79877dbd9379285cf8789c9e0879293d`](https://huggingface.co/FunAudioLLM/CosyVoice2-0.5B/blob/eec1ae6c79877dbd9379285cf8789c9e0879293d/README.md) declares Apache-2.0. The official [CosyVoice code LICENSE at `074ca6dc9e80a2f424f1f74b48bdd7d3fea531cc`](https://github.com/FunAudioLLM/CosyVoice/blob/074ca6dc9e80a2f424f1f74b48bdd7d3fea531cc/LICENSE) contains Apache License 2.0; a provenance copy is retained under `ThirdParty/TranslationCascade/licenses/`. This establishes the stated upstream license and origin. It **does not independently establish the conversion author's license, a conversion source pin, or that every converted tensor is accounted for**. The conversion remains a visible provenance gap; do not relabel or redistribute it as fully license-verified based solely on the upstream card.

The separate `mlx-community/CosyVoice2-0.5B-S3Tokenizer` repository declares Apache-2.0, but its filename/layout differs. No silent substitution was made. All current S3 hashes remain those in `TranslationSpeechPreparation`; the runtime receives the selected prepared tokenizer path and never downloads one implicitly.

## Validation boundaries

The two small source recordings and license were fetched directly from the pinned creator repository and their hashes, PCM format and duration were checked. Deterministic tests cover read-only verification, immediate cancellation, corrupt download rejection, and opt-in installation/idempotence/license integrity. Set `NATIV_STOCK_VOICE_FIXTURES` to the separate directory containing the two pinned source WAVs and `LICENSE` for that artifact test. It loads no TTS model and does not count as a Chatterbox rendering or human voice assessment.

On 8 November 2026, a lightweight SwiftPM harness compiled the actual stock helper, model store and disk-capacity implementation against `NativTranslationKit`. All four stock tests passed, including the pinned artifact installation, offline reuse and repair of a corrupted license. This checks artifact preparation independently of an app build; native app integration and rendered voice quality are separate checks.

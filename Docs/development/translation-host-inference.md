# Opt-in proef van de echte Swift-hostcascade

`TranslationCascadeInferenceTests.testExplicitOwnedHostCascadeSyntheticInference` gebruikt de daadwerkelijke `TranslationCascadeProviders.make`, de bestaande modelinventaris en Whisper-assetvoorbereiding, de eigen MLX-runtime, de echte resourceleases en lazy LFM3-Omni-TTS. Het testpakket vraagt geen microfoon- of opnamepermissie en speelt geen audio af. Het voert twee expliciet opgegeven synthetische WAV-bestanden door, Nederlands → Engels en Engels → Nederlands.

Dit is een afzonderlijke technische proef. Zonder beide opt-in-variabelen eindigt de test met `XCTSkip`, niet met een gemeten inferentiepass. Een pass verifieert brontranscript, vertaaltekst, werkelijk ontvangen niet-lege PCM en voltooide turns in de juiste volgorde. Hij kwalificeert geen betekenisbehoud, natuurlijke stemmen, menselijke acceptatie of akoestische latency.

## Voorbereiding

1. Bouw de fork en zijn testtargets zoals beschreven in de normale ontwikkelinstructies. De test hoort bij `NativTests` en gebruikt dezelfde bronbestanden als de app.
2. Installeer de gekozen gepinde ASR en LLM expliciet via Models; prepareer Whisper's processorbestanden indien nodig. Deze test downloadt niets en kiest geen ander model.
3. Gebruik een vooraf geverifieerde eigen MLX-launcher en llama.cpp-helper. Geef de concrete Omni-model- en projectorbestanden op; SHA-256 en bestandsgrootte worden gecontroleerd.
4. Gebruik twee originele synthetische fixtures van maximaal twaalf seconden, mono PCM16 op 16 kHz. Gebruik ze niet als vervanging voor de afzonderlijke menselijke proef met nieuwe opnamen.
5. Maak een lokaal JSON-manifest met onderstaande structuur. `artifacts` is voor ASR en LLM de volledige artifactlijst uit [model-manifest.json](../../ThirdParty/TranslationCascade/model-manifest.json), met de corresponderende repository als `modelID`. Gebruik de exacte Omni-artifacts uit de gepinde runtime-manifest. Fixturehashes moeten bij de gekozen lokale bestanden horen; placeholders worden geweigerd.

```json
{
  "modelSearchPath": "/absolute/HuggingFace/hub",
  "mlxExecutable": "/absolute/NativServerKit.framework/Resources/mlx-vlm-server/bin/mlx-vlm-server",
  "strategy": "sequential",
  "recognition": {
    "modelID": "mlx-community/whisper-large-v3-turbo",
    "revision": "a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb",
    "artifacts": ["REPLACE WITH THE FULL PINNED ARTIFACT OBJECT ARRAY"]
  },
  "translation": {
    "modelID": "mlx-community/gemma-4-e4b-it-4bit",
    "revision": "475b9088d29754a3379866cf5aeb6b41acd313c2",
    "artifacts": ["REPLACE WITH THE FULL PINNED ARTIFACT OBJECT ARRAY"]
  },
  "omni": {
    "executable": "/absolute/runtime/bin/llama-server",
    "directory": "/absolute/prepared/omni-models",
    "model": {"filename": "LFM3-Omni-2B-Q8_0.gguf", "size": 0, "sha256": "REPLACE"},
    "projector": {"filename": "mmproj-LFM3-Omni-2B-Q8_0.gguf", "size": 0, "sha256": "REPLACE"}
  },
  "fixtures": [
    {"source": "nl", "target": "en", "directory": "/absolute/synthetic-fixtures", "synthetic": true,
     "artifact": {"filename": "synthetic-nl.wav", "size": 0, "sha256": "REPLACE"}},
    {"source": "en", "target": "nl", "directory": "/absolute/synthetic-fixtures", "synthetic": true,
     "artifact": {"filename": "synthetic-en.wav", "size": 0, "sha256": "REPLACE"}}
  ]
}
```

Het manifest is een expliciete proefkeuze. Een kleinere LLM of `resident`-modus moet een apart benoemd manifest en rapport krijgen; de harness vervangt geen profiel stilzwijgend.

De helper maakt het manifest uit de repositorypins en gehashte synthetische fixtures, zonder modelgewichten te laden of te downloaden:

```sh
python3 scripts/translation_host_inference_manifest.py \
  --model-cache /absolute/HuggingFace/hub \
  --mlx-executable /absolute/mlx-vlm-server/bin/mlx-vlm-server \
  --llama-executable /absolute/runtime/bin/llama-server \
  --omni-directory /absolute/prepared/omni-models \
  --nl-synthetic-fixture /absolute/synthetic-fixtures/synthetic-nl.wav \
  --en-synthetic-fixture /absolute/synthetic-fixtures/synthetic-en.wav \
  --translation-profile gemma-4-e4b-it-4bit \
  --strategy sequential --output /absolute/host-cascade-manifest.json
```

Gebruik voor native tests bij voorkeur een aparte validatiemap onder `~/Library/Developer/NativLiveTranslationValidation` wanneer de werkmap op Desktop onder TCC valt. Houd het codecheckout, de helpers, fixtures en geselecteerde cache-artifacts bereikbaar voor de native testhost. Een APFS-kopie met `cp -cR` kan bestaande bestanden delen zonder alle modelbytes opnieuw te downloaden. Kopieer bij een Hugging Face-model de complete `models--…`-map inclusief blobs en relatieve snapshotsymlinks. Prepareer de Whisper-composite opnieuw tegen het nieuwe snapshot: bestaande absolute symlinks naar een beschermde Desktop-map geven geen geldige TCC-isolatie. Zet alle absolute paden in het manifest naar deze validatiekopieën; de originele repository en cache blijven intact.

## Uitvoeren en rapporteren

Geef de variabelen via de testplanomgeving door, of met de Xcode-test-runnerprefix:

```sh
TEST_RUNNER_NATIV_CASCADE_HOST_INFERENCE=1 \
TEST_RUNNER_NATIV_CASCADE_HOST_MANIFEST=/absolute/host-cascade-manifest.json \
xcodebuild test -project Nativ.xcodeproj -scheme Nativ \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:NativTests/TranslationCascadeInferenceTests/testExplicitOwnedHostCascadeSyntheticInference \
  -parallel-testing-enabled NO \
  -resultBundlePath /absolute/HostCascadeInference.xcresult
```

De test vereist normale geheugendruk en leesbare swaptelemetrie vóór de eerste modellading. Elke ASR/LLM/TTS-fase heeft een limiet van zestig seconden. Een experiment stopt bij ontbrekende telemetrie, kritieke systeemgeheugendruk, meer dan 1 GiB toename in globale swap of een totale looptijd van 420 seconden. Globale swap kan door andere processen veranderen; een afgebroken proef is daarom geen gemeten exclusieve geheugenbehoefte van het model. Alleen de eigen twee helpers worden gestopt en alle output wordt direct bevestigd aan het begrensde transportbudget.

Het log noemt exacte ASR-/LLM-revisies, geheugenstrategie, ontvangen PCM-bytes en commit-tot-eerste-ontvangen-PCM. Dit is geen microfoon- of luidsprekermeting. Bewaar het manifest en het `.xcresult` naast het rapport en vermeld mislukte of overgeslagen proeven expliciet. Voor menselijke kwalificatie blijven de oorspronkelijke aantallen, taalrichtingen, warme/koude metingen en duurtest gelden.

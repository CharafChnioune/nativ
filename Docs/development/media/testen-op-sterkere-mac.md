# Music en Video testen op je sterkere Mac

De code bevat de native schermen, providers, API, duurzame jobs, Chat/Artifacts,
playback, export en beheerde installatie. Op de 16 GB-ontwikkelmachine zijn de
generatiemodellen **niet uitgevoerd**; op de M3 Max wel (zie de stand hieronder).
Er zijn geen betaalde proefaanvragen gedaan. Een geslaagde build, mocktest of
meting kwalificeert een model niet.

## Stand op de M3 Max (10 november 2026)

Apple M3 Max (16 cores), 128 GiB, macOS 27.2, Xcode 27.2/Swift 6.4.2. Elke meting
hoort bij de verplaatste ad-hoc-kandidaat waarop ze is gedaan. De productcode is
gemeten op `6f4ae0c3` en Wan op `3f92ecdf` (de Wan-workercode is daarna niet
gewijzigd); Images en Translate volgen op `2e5bf71e`. Eerdere kandidaten:
`181a78c3`, `f17ea0a9`, `29cbf1f4`, `fca2a3d3` en `5288300c`. Lokale media draait
alleen op MLX: video via [mlx-video](https://github.com/Blaizzy/mlx-video) `87db56a`
met LTX-2.3 distilled (alleen tekst-naar-video) en Wan2.2 TI2V-5B Q8, muziek via
MiniMax Music3 (mlx-audio) en Stable Audio 3 Small (officieel, pure MLX). De
eigenaar heeft de licenties van de installeerbare profielen geaccepteerd.

Gedaan:

- Mocks/unit-tests, zonder modellen: native ronde op `181a78c3` met 1.906 tests,
  1.896 geslaagd, 0 fouten, 10 overgeslagen en alle 29 verplichte classes;
  gebundelde Python 341/341 op elke kandidaat van `f17ea0a9` tot en met
  `6f4ae0c3`; Python 3.12-venv 341 OK met 1 opt-in-skip. CI "Live Translate
  validation" (push en PR, inclusief native tests en Required validation gate)
  groen op `bbfb61b2` (42689873987, 42689884606) en `f17ea0a9` (42699682243,
  42699692503).
- Verpakte app: headless server uit de verplaatste kandidaat op 127.0.0.1:8181;
  401 zonder sleutel, 428 zonder store-header, 409 bij een andere store. De
  store-ID blijft behouden na herstart en app-upgrade; codesign blijft geldig vóór
  en na serverstart en importcontrole.
- Runtimes vanuit Nativ: installeren en repareren voor alle vier MLX-profielen,
  verwijderen en herinstalleren voor Stable (modellen blijven bewaard).
  Gelijktijdige setup wordt geweigerd met `compute_busy`; een tweede job wachtte
  139,7 s in `queued`. Repareren zonder download duurt 13–62 s. Een runtime met
  workercode van een andere Nativ-build staat in de lijst als "Repair this
  runtime", submit geeft 409 en dispatch/herstel `runtime_outdated`; na een update
  van `nativ_generation` is per geïnstalleerd profiel één Repair nodig. Zie
  [`evidence/m3-runtime-lifecycle.json`](evidence/m3-runtime-lifecycle.json).
- Muziek: 10 MiniMax- en 2×10 Stable-generaties via de canonieke API; drie
  MiniMax-annuleringen bereikten `cancelled` binnen 0,06 s zonder achterblijvende
  workers. De MiniMax-voetafdruk van 34–46 GB is gemeten vóór de cachelimiet van
  `29cbf1f4` en niet opnieuw gemeten. Zie
  [Music-kwalificatie](../music-runtime-qualification.md#m3-max-results) en
  [`evidence/m3-music-qualification.json`](evidence/m3-music-qualification.json).
- Video: Wan2.2 4/4 (twee T2V, twee I2V) op `3f92ecdf`, 1.079–1.103 s per clip;
  LTX-2.3 4/4 T2V op `6f4ae0c3`, 91,9 s voor de eerste en 78,4–78,5 s voor de
  volgende jobs. Alle clips decoderen zonder fouten en spelen af in AVFoundation.
  LTX-annuleringen tijdens laden, denoisen en VAE-decode bereikten `cancelled`
  binnen 0,06 s. Zie
  [Video-kwalificatie](../video-runtime-qualification.md#m3-max-results) en
  [`evidence/m3-video-qualification.json`](evidence/m3-video-qualification.json).
- Gedeelde jobflows op `6f4ae0c3`: idempotency (zelfde sleutel geeft dezelfde job,
  een gewijzigde body 409), twee clients met dezelfde eindstaat en asset,
  worker-SIGKILL, 20 opeenvolgende jobs zonder groei van open bestanden of
  workers, een extern vastgehouden Translate-flock die generatie in `queued` houdt
  en een server-SIGKILL tijdens een LTX-job (geen wezen; na herstart
  `interrupted`, niet opnieuw uitgevoerd).
- Gevonden en hersteld op de M3: MLX-buffercache (`29cbf1f4`), `fd`-protocol in de
  beheerde FFmpeg (`2f5b4be9`), LTX-mux zonder `-shortest` (`862c0c3b`),
  verouderde runtimecode weigeren en tonen (`5288300c`, `2e5bf71e`), LTX-2.3
  alleen tekst-naar-video (`6f4ae0c3`) en de Images-thread die zijn eigen
  compute-flock opnieuw claimde (`21e2f89c`).

Bewust open (eigenaar: "nu niet"): menselijke luister- en kijkbeoordeling,
menselijke Translate-opnames en fysieke UI-tests. H3 blijft geblokkeerd (geen
checkpointinventaris; de licentie sluit de EU uit). ACE-Step is uitgeschakeld
(PyTorch op MPS met een MLX-DiT, niet in mlx-audio): zichtbaar met reden,
installatie geweigerd. Restrisico: de video's hebben geen kleurtags, dus de
speler kiest zelf BT.601 of BT.709. Alle profielen blijven
experimenteel/ongekwalificeerd; niets slaagt automatisch en resultaten op 128 GB
kwalificeren geen 16 GB-Mac. Developer ID, notarisatie, een echte Sparkle-upgrade
en betaalde cloudproeven blijven afzonderlijke gates.

### TODO: Images-resultaten (FLUX.2-klein-4B op `2e5bf71e`)

Nog niet ingevuld; de cijfers volgen. De eerste poging op `6f4ae0c3` gaf bij elke
generatie HTTP 500, omdat de Images-thread zijn eigen compute-flock opnieuw
claimde; hersteld in `21e2f89c`.

### TODO: Translate-resultaten (op `2e5bf71e`)

Nog niet ingevuld; de cijfers volgen.

## Dezelfde kandidaat bouwen

Begin bij de actuele overdracht in [`prompt.md`](../../../prompt.md). PR #2
was bij overdracht nog open: de code staat op `codex/music-video-generation`,
niet alleen op de oude `main`. Controleer de actuele PR/CI-status en gebruik de
revisie uit dat rapport. Bewaar je
bestaande modellen en gegevens; een schone gebruikersbibliotheek is niet nodig.
Voor een developmentbuild zijn Xcode, XcodeGen en CMake nodig. Die ontwikkeltools
zijn geen verplichte Homebrew-installatie voor eindgebruikers van een verpakte app.

```sh
git fetch origin
git switch codex/music-video-generation
git pull --ff-only
python3 PythonDistribution/CodecRuntime/manage.py build
NATIV_REQUIRE_MANAGED_CODECS=YES make xcode-build
python3 scripts/sign_macos_local.py build/NativDevelopmentDerivedData/Build/Products/Debug/Nativ.app
```

Dit is een lokaal ondertekende developmentbuild. Developer ID, notarisation en
een echte ondertekende oud-naar-nieuw-update blijven afzonderlijke releasegates.
De bestaande fork-Sparklefeeds en publieke sleutel blijven behouden.

Open de kandidaat met de bestaande developmentprocedure uit de repository.
Stel in Developer een API-sleutel in en start de Nativ-server. De standaardpoort
is 8181. Open Music of Video en kies **Providers and runtimes**. Accepteer de
toepasselijke licenties, schakel het gewenste experimentele profiel expliciet in
en kies Install. De video-inventarissen (LTX-2.3, Wan2.2) bevatten geen gated
componenten; daarvoor is geen Hugging Face-sleutel nodig. Toont een geïnstalleerd
profiel na een app-update "Repair this runtime", kies dan Repair; dat downloadt
geen modellen.

Er is geen automatische cloudfallback. Een grotere Mac maakt een model niet
vanzelf gekwalificeerd. Controleer de vereiste vrije schijfruimte in de inventaris;
de checkpointgrootte is geen gemeten piek-RAM. LTX-2.3 (ongeveer 73,5 GB) en
Wan2.2 (ongeveer 19,6 GB) hebben afzonderlijke inventarissen en elk een eigen
runtimemap. H3 blijft geblokkeerd zonder checkpointinventaris, passende licentie
én vastgelegde hardwarekwalificatie.

## Muziekproef

Gebruik de Python-interpreter van de kandidaat, of een geschikte lokale Python
voor de testdriver. Geef alleen de API-sleutel van je eigen Nativ-server via de
omgeving door; zet geen sleutel in een rapport of Git.

```sh
python3 scripts/benchmarks/music/qualify.py --output build/validation/music-qa
# Bekijk eerst de dry-run en stel NATIV_TOKEN lokaal in.
python3 scripts/benchmarks/music/qualify.py --run-models \
  --base-url http://127.0.0.1:8181 --output build/validation/music-qa
```

De corpus bevat 20 originele cases: tien MiniMax MLX en tien Stable Small Music,
elk met één herhaling met dezelfde seed. ACE-Step is uitgeschakeld. Minimaal vijf
echte resultaten per vrijgegeven lokale provider zijn vereist. Hervat met dezelfde
uitvoermap: de driver bewaart intenten, store-ID en job-ID en maakt bij onzekere
acceptatie geen nieuwe generatie aan.

Luister naar de originele bestanden en vul `quality-review.json` in. Beoordeel
volledigheid, clipping, toonhoogte, timing, stijl en opgegeven lyrics. De driver
zet nooit automatisch `qualified=true`. De systeemgeheugenmetingen zijn
observaties van de driver-Mac, geen geïsoleerde modelpiekmeting.

## Videoproef

Lees de lokale opties vóór uitvoering:

```sh
python3 scripts/benchmarks/video/qualify.py --help
```

De Video-driver voert zonder expliciete uitvoeringsoptie geen generatie uit.
Volg de concrete opdrachten in
[Video-kwalificatie](../video-runtime-qualification.md). Gebruik per lokaal
profiel minimaal vier clips en alle geadverteerde workflows, inclusief I2V waar
aangeboden (LTX-2.3 biedt alleen tekst-naar-video; Wan2.2 is het lokale
I2V-profiel), portret/landschap en native audio waar ondersteund. Bewaar dezelfde ledger bij
herstart. Een `retrieval_pending`-resultaat vereist beoordeling; het is geen
bewijs dat het model klaar of geslaagd is.

Controleer eerste, middelste en laatste frames, werkelijke FPS en frameaantal,
begin/einde, seek, bewegingskwaliteit en geluidssynchronisatie. De kleine
H.264/AAC-markerproef uit de ontwikkeling valideert uitsluitend de mediapipeline.

## Gezamenlijke acceptatie

Test vanuit twee vensters en via de API dezelfde jobs, playback, export,
Chat-verwijzingen, Artifacts, prullenbak/herstel en herstart. Test annulering
tijdens voorbereiding, inferentie en encoding, plus een onverwachte serverstop.
Een actief Translate-gesprek moet nieuwe zware lokale generatie tegenhouden.
Microfoonactiviteit moet media eerst pauzeren; stoppen met opnemen mag media niet
automatisch hervatten. Controleer ook Chat, Images, STT/TTS en modelbeheer.

Leg chip, RAM, macOS, exacte model- en runtimepins, koude/warme tijden,
geheugendruk/swap, annulering en resterende processen vast. Test 16 GB en 128 GB
als afzonderlijke hardwareprofielen wanneer beschikbaar. De huidige code claimt
geen gemeten ondersteuning voor een niet-geteste geheugengrootte.

Een betaalde cloudproef vereist een eigen expliciete opdracht/budget en geschikt
account. Ondertekenings- en echte upgradeproeven gebeuren pas bij een afzonderlijk
geautoriseerde release. De automatische upstreamsync blijft kandidaten en checks
maken; een conflictvrije merge alleen is geen kwalificatie.

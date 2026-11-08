# Music en Video testen op je sterkere Mac

De code bevat de native schermen, providers, API, duurzame jobs, Chat/Artifacts,
playback, export en beheerde installatie. De echte generatiemodellen zijn op de
16 GB-ontwikkelmachine **niet uitgevoerd**. Er zijn geen betaalde proefaanvragen
gedaan. Een geslaagde build of mocktest kwalificeert een model niet.

## Dezelfde kandidaat bouwen

Gebruik de definitieve Music/Video-revisie uit het GitHub-PR-rapport. Bewaar je
bestaande modellen en gegevens; een schone gebruikersbibliotheek is niet nodig.
Voor een developmentbuild zijn Xcode, XcodeGen en CMake nodig. Die ontwikkeltools
zijn geen verplichte Homebrew-installatie voor eindgebruikers van een verpakte app.

```sh
git fetch origin
git switch main
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
en kies Install. Voor gated Hugging Face-componenten moet je account toegang
hebben en moet de Hugging Face-sleutel in Nativ zijn ingesteld.

Er is geen automatische cloudfallback. Een grotere Mac maakt een model niet
vanzelf gekwalificeerd. Controleer de vereiste vrije schijfruimte in de inventaris;
de checkpointgrootte is geen gemeten piek-RAM. Q4 en Q8 hebben afzonderlijke
inventarissen. H3 blijft geblokkeerd zonder passende licentie én vastgelegde
hardwarekwalificatie.

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

De corpus bevat 20 originele cases: acht ACE, zes MiniMax MLX en zes Stable Small
Music. Minimaal vijf echte resultaten per vrijgegeven lokale provider zijn
vereist. Hervat met dezelfde uitvoermap: de driver bewaart intenten, store-ID en
job-ID en maakt bij onzekere acceptatie geen nieuwe generatie aan.

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
profiel minimaal vier clips en alle geadverteerde workflows, inclusief I2V,
portret/landschap en native audio waar ondersteund. Bewaar dezelfde ledger bij
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

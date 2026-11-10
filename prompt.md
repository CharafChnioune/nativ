# Opdracht voor Codex op de Mac M3 met 128 GB — Nativ afmaken

> **Status (10 november 2026):** dit is de oorspronkelijke overdracht. De
> profiellijst hieronder is historisch: lokale media draait nu alleen op MLX
> (mlx-video met LTX-2.3, alleen tekst-naar-video, en Wan2.2; LTX-2.5 Q8/Q4
> verwijderd, ACE-Step uitgeschakeld). Muziek, video, gedeelde jobflows en
> runtimebeheer zijn op de M3 Max gemeten; Images en Translate volgen. Niets is
> gekwalificeerd. Actuele stand, metingen en bewust open gates:
> [`Docs/development/media/testen-op-sterkere-mac.md`](Docs/development/media/testen-op-sterkere-mac.md#stand-op-de-m3-max-10-november-2026).

Voer deze opdracht uit; stop niet na een nieuw plan. Je neemt bestaand werk over
van een M5 met 16 GB. De gebruiker wil op deze sterkere Mac de resterende
implementatie, echte modelproeven, reparaties en integratie afronden. Communiceer
in het Nederlands, zonder emoji's. Gebruik maximaal drie gespecialiseerde
subagents naast de integrator, met afzonderlijk bestandseigenaarschap.

## Repository en eerste handelingen

- Fork: https://github.com/CharafChnioune/nativ (`origin`).
- Upstream: https://github.com/Neywa-Labs/nativ (`upstream`).
- Werkbranch: `codex/music-video-generation`.
- Bestaande draft-PR: https://github.com/CharafChnioune/nativ/pull/2.
- Laatste productcode bij overdracht: `c24781b73e64aec7a853b8f44ea0fe2465f1b5e6`.
  Latere overdrachtscommits bevatten dit bestand en bewijs. Fetch de actuele HEAD;
  gebruik bovenstaande SHA als referentie, niet om nieuwe commits te verwijderen.
- `main` stond bij overdracht op `e22f7b9333a4ff7437bd81879454f050cbb3c6b9`.
  Translate PR #1 is daarin normaal gemerged. Music/Video PR #2 was nog open.
  Begin dus NIET uitsluitend vanaf de oude main zonder de featurebranch te lezen.

Bij een nieuwe, lege werkmap kun je starten met:

```sh
git clone --branch codex/music-video-generation https://github.com/CharafChnioune/nativ.git nativ
cd nativ
git remote add upstream https://github.com/Neywa-Labs/nativ.git
git fetch origin
git fetch upstream
```

Bij een bestaande checkout: inspecteer eerst status, remotes, branches, worktrees
en ongecommitteerde wijzigingen. Behoud alles; geen hard reset, force-push of
blind overschrijven. Lees alle actuele toepasselijke AGENTS.md/instructies.
Controleer werkelijke chip, RAM, macOS, Xcode/Swift, vrije opslag en swap; neem
"M3/128 GB" niet als gemeten systeemconfiguratie over.

Lees vervolgens volledig:

1. `Nativ_Music_Generation_Codex_Prompt.txt`.
2. `Nativ_Video_Generation_Codex_Prompt.txt`.
3. `Nativ_Live_Translate_Codex_Prompt.txt`, met behoud van de hieronder genoemde
   aanvullingen van de gebruiker.
4. `Docs/development/media/implementation-plan.md`,
   `Docs/development/media/testen-op-sterkere-mac.md` en alle relevante
   review-/bewijsbestanden in `Docs/development/media/evidence/`.
5. `Docs/development/music-runtime-qualification.md`,
   `Docs/development/video-runtime-qualification.md`,
   `Docs/development/live-translation-delivery.md` en
   `Docs/development/live-translation-acceptance.md`.
6. `Docs/api/music.md`, `Docs/api/video.md`, `project.yml`, Makefile,
   PythonDistribution, tests en bestaande CI/upstreamsync/releaseworkflows.

Specificaties en actuele code zijn leidend. Oudere checkpointteksten beschrijven
historische tussenstanden. Maak een interne checklist en verifieer de echte
implementatie; ga niet uit van voltooiing omdat een onderdeel al code heeft.

## Actuele verificatie en eerste open blokkade

Snapshot bij overdracht op 9 november 2026:

- Op `c24781b7` zijn beide GitHub-appbuilds met Xcode 26.6 geslaagd. De eerdere
  compilercrash bij twee actor-methodereferenties in seek-sliders is daarmee
  niet meer de actuele blokkade; de expliciete closures moeten behouden blijven.
- Push-run **42529891583** heeft alle verplichte jobs en de gate groen:
  https://github.com/CharafChnioune/nativ/actions/runs/42529891583.
- PR-run **42529898161** heeft groene identity/Python/Swift, maar faalt in de
  native testronde en dus terecht in `Required validation gate`:
  https://github.com/CharafChnioune/nativ/actions/runs/42529898161.
- De twee concrete fouten zitten in
  `Tests/NativTranslationKitTests/TranslationCoreTests.swift`:
  `stopCancelsOutstandingSendBeforeReleaseBarrier()` (regel 529 op deze revisie,
  `await backend.didStop`) en
  `newSpeechDuringContextReleaseWaitsForFreshStart()` (regel 639,
  `await backend.frames.last?.turnID == next`).
- De bijbehorende native job is **128881584720**, XCResult-artifact
  **13637717303**. Download en lees het echte resultaat wanneer nodig:
  https://github.com/CharafChnioune/nativ/actions/runs/42529898161/artifacts/13637717303.
- Dezelfde productrevisie slaagt in de push-run. Onderzoek dit verschil gericht;
  noem het niet zonder bewijs uitsluitend een flaky test. Maak onderscheid tussen
  een productrace en wachten op niet-gegarandeerde Task.yield-scheduling. Herstel
  de oorzaak, behoud inhoudelijke assertions en test daadwerkelijke mijlpalen.
  Geen skips, weggenomen tests, verlaagde gates of onbewezen timeoutverruiming.

Lokaal bewijs van de 16 GB-Mac:

- Volledige native ronde op `47eeae86`: 1.895 geslaagd, 10 overgeslagen, 0 fouten;
  alle 29 vereiste Translate/Generation-testclasses uitgevoerd.
- Volledige daadwerkelijk gebundelde Python op `45730360`: **337/337 geslaagd**,
  geen skips, inclusief `NATIV_CASCADE_RUNTIME_CHECK=1` zonder modelgewichten.
- Volledige lokale appbuild en zes gerichte playback/Music/Video-tests op de
  compatibiliteitswijziging `c24781b7` zijn geslaagd.
- Ondertekende, verplaatste developmentapp op `c24781b7`: echte serverstart,
  bearer-auth, gedeelde Music/Video-store, 7 Music- en 9 Video-profielen,
  bestaande Chat-route en health getest. Ondertekening bleef vóór/na serverstart
  en gebundelde-importcontrole geldig. Geen model geladen of betaalde call gedaan.
- Echte kleine codec-/AVFoundation-markerproeven en een kleine C-extensieproef
  zijn uitgevoerd. Dit bewijst GEEN volledige modelinstallatie of generatie.

De code wordt nog niet als volledig gekwalificeerd opgeleverd. De PR blijft open
zolang de vereiste exacte-head-controles niet betrouwbaar slagen. Controleer
nieuwere runs opnieuw; bovenstaande uitslagen horen alleen bij de genoemde SHA's.

## Bestaande architectuur behouden en afmaken

Er is één `nativ_generation`-kern met SQLite-jobs, events, inputs, assets,
referenties en een schedulerlock. `nativ_music` en `nativ_video` hebben afzonderlijke
providerinterfaces, maar delen deze kern, authenticatie en resourceleases.
Swift-clients, native werkruimtes, Chat-tools en Artifacts gebruiken dezelfde jobs.

Behoud bearer-auth, verplichte idempotency, `X-Nativ-Store-ID` (428 ontbrekend,
409 verkeerd), poging-/generatiefencing, journal vóór verzending, herstelstaten
inclusief `submission_unknown` en `retrieval_pending`, en geen automatische
herhaling van onzekere betaalde submissions. Een downloadretry mag geen nieuwe
generatie starten. Serverwissel of vervangen database mag oude intenten niet
naar een andere store verplaatsen. Python blijft eigenaar van originele media.

Behoud de wachtrijlimieten en werkelijk vastgehouden compute-/audioleases tot
workers/encoders gestopt zijn. 128 GB is geen reden om beperkingen stil te verruimen
of een actief Translate-gesprek te onderbreken. Externe API-clients mogen de
native resourcebeperkingen niet omzeilen. Geen stille lokale/cloud-modelwissel.

## Bouwen en deterministisch testen op de M3

Lees eerst de actuele buildinstructies en scripts. Een verse checkout bevat geen
DerivedData, geïnstalleerde modelruntimes, gewichten, binaries of privésleutels.
Installeer zo nodig de development-buildtools; eindgebruikers mogen geen verplichte
Homebrew-/terminal-/pipstap krijgen bij het starten van de app.

Voorbeeld van de bestaande ontwikkelroute (pas paden aan jouw checkout aan):

```sh
python3 PythonDistribution/CodecRuntime/manage.py build
NATIV_REQUIRE_MANAGED_CODECS=YES make xcode-build
swift test --parallel
```

Voer de Python-suite uit met Python 3.12 en de hash-gepinde
`scripts/generation-test-requirements.txt`, en vervolgens met de daadwerkelijk
gebundelde interpreter. Gebruik bij die tweede ronde:

```sh
NATIV_CASCADE_RUNTIME_CHECK=1 PYTHONDONTWRITEBYTECODE=1 \
  build/NativDevelopmentDerivedData/Build/Products/Debug/Nativ.app/Contents/Frameworks/NativServerKit.framework/Resources/mlx-vlm-server/python/bin/python3 \
  -B -W error::ResourceWarning -m unittest discover -s scripts/tests -v
```

Voer de volledige geconfigureerde Xcode-tests uit met een NIEUW XCResult-pad,
`CODE_SIGNING_ALLOWED=NO`, de juiste `NATIV_FORK_REVISION` en
`NATIV_SKIP_PYTHON_RESOURCE_BUILD=YES` na een geldige volledige build. Controleer
het resultaat met `scripts/verify_translation_test_results.py`. Alleen een groen
buildcommando of een leeg testplan is onvoldoende.

Werk sequentieel aan één appbundel: laat Xcode niet kopiëren terwijl andere tests
zijn gebundelde Python gebruiken. Sommige setup-testfixtures starten Python met
`-I` en herschrijven bytecode. Volg daarom tests → definitief signen → veilige
`-B` server-/importsmoke → codesign-sealcheck. `-I` negeert omgevingsinstellingen
zoals PYTHONDONTWRITEBYTECODE, dus gebruik ook expliciet `-B` waar nodig.

Gebruik `scripts/sign_macos_local.py` voor een lokale ad-hoc kandidaat en
`scripts/fork_release.py bundle APP --sha EXACT_SHA --verify-imports` voor de
lokale gecontroleerde bundelcontrole. Een ad-hoc app is geen Developer ID-release.
Bewaar codec-buildprovenance; signerhelpers actualiseren alleen de werkelijk
opnieuw ondertekende bestanden vóór de bovenliggende resource-seal.

## Echte modelinstallatie en kwalificatie

Voer op deze Mac nu de haalbare lokale modelproeven uit, sequentieel en met
metingen. Begin met één profiel; volledige dependencies/gewichten/installaties
zijn nog niet op echte modellen gekwalificeerd. Controleer officiële bronnen,
licenties, exacte revisions, hashes, volledige artifacts en ABI-compatibiliteit.
Behoud bestaande pins tenzij een aangetoonde incompatibiliteit een gecontroleerde
wijziging vereist. Noteer dan reden, nieuwe pins, tests en regressies.

Music-profielen: ACE-Step 1.5 Turbo, MiniMax Music3 MLX, Stable Audio 3 Small Music
MLX; daarnaast geïmplementeerde MiniMax GPU/cloud, Lyria 3.5 en Stable Audio cloud.
Video-profielen: LTX-2.5 Distilled Q8/Q4, Wan2.2 TI2V-5B; daarnaast H3-adapter,
LTX V2 en Runway Gen-4.5. De daadwerkelijke manifests/catalogi zijn leidend.

- Installeer/herstel/verwijder vanuit Nativ en test de volledige geïsoleerde
  runtime vanuit een verplaatste verpakte app buiten de sourcecheckout.
- Test alle native imports, model-loaders, helpers, parent-death/cancel-cleanup,
  FFmpeg/x264 en receipts. Het kleine succesvolle native-wheel-signingbewijs
  is geen bewijs dat alle MLX/dependencycombinaties werken.
- Gebruik de bestaande Developer/Hugging Face-Keychainintegratie voor gated LTX;
  vraag alleen noodzakelijke account-/licentietoegang. Geen token in Git/logs.
  LTX-inventaris moet alle exacte componenthashes kunnen oplossen.
- H3 blijft geblokkeerd totdat licentie, echte volledige checkpointinventaris én
  hardware geschiktheid zijn aangetoond. Een mock-adapter maakt H3 niet inzetbaar.
- Geen betaalde cloud-/GPU-proeven zonder afzonderlijk expliciet budget en geschikt
  account. Geen cloudfallback als lokaal een proef faalt.
- Meet download/load/inferentie/decode/encode/import afzonderlijk, koude en warme
  omstandigheden, RSS/MLX-geheugen, systeemdruk/swap, annulering en achterblijvende
  processen. Worker-per-job-loadtijd mag niet als een warm resident model gelden.
- Kwalificatie op M3/128 GB kwalificeert 16 GB of andere chips/talen niet automatisch.
  Behoud passende waarschuwingen/admission op kleinere Macs; checkpointgrootte is
  geen gemeten piek-RAM. Toon experimenteel/ongekwalificeerd zolang bewijs ontbreekt.

Start de bestaande kwalificatiedrivers eerst zonder `--run-models`. Music gebruikt
standaard `NATIV_TOKEN`; Video gebruikt standaard `NATIV_KEY`. Lees hun `--help`
voor de actuele opties. Stel tokens lokaal veilig in, nooit in dit document.

```sh
python3 scripts/benchmarks/music/qualify.py --output build/validation/music-qa
python3 scripts/benchmarks/video/qualify.py --help
```

Behoud dezelfde outputledger bij hervatten: geen nieuwe idempotency-key of POST
wegens onzekere acceptatie. Music: minimaal 20 originele generaties en minimaal
5 per vrijgegeven lokale provider, met menselijke luisterbeoordeling. Video:
minimaal 4 clips per vrijgegeven lokaal profiel, met alle aangeboden T2V/I2V-,
portret/landschap-, seed- en audio-workflows. Beoordeel betekenis/lyrics, kwaliteit,
clipping, bewegings-/referentietrouw, frames/FPS, kleur/orientatie, seek, soundtrack
en synchronisatie. Laat menselijke kwaliteit niet automatisch slagen.

Voer ook echte bestaande Images-generatie/editing uit. Controleer tijdens zware
inferentie dat health/status/events/cancel bereikbaar blijven. Presets en
provideropties mogen geen niet-ondersteunde parameters stil negeren.

## Translate en gezamenlijke gebruikersflows

Behoud de gebruikerskeuzes: lokale open modellen als hoofdroute; LFM3-Omni direct
→ dezelfde Omni in twee passes → expliciet gekozen alternatief. Apple TTS is
uitsluitend een handmatige extra optie, nooit automatische hoofdroute/fallback.
STT, LLM en TTS moeten onafhankelijk combineerbaar blijven; rapporteer herkenning,
vertaling en spraaktaalondersteuning afzonderlijk. Geen Nederlands-only TTS-aanname.

Lees bestaand Translate-bewijs en rond resterende echte cascade-/Omni-proeven af.
Onderzoek kritieke getal-/ontkenningsfouten. Nieuwe menselijke opnames en
stembeoordeling zijn nodig voor echte kwalificatie: minimaal 30 turns per richting,
90% betekenisbehoud zonder kritieke getal-/ontkenningsfouten, natuurlijke/expressieve
verstaanbare stem, minimaal 100 warme metingen, 10 koude starts en 30 minuten
gebruik. Latencydoelen zijn geen behaalde cijfers. Behoud de specifieke
buffer-/contextgrenzen en late-event/generation-invalidatie uit de specificatie.

Test Music/Video/Images/Chat/Translate/STT/TTS samen: twee vensters, serverwissels,
vervangen store, crash/herstart, idempotency, annulering tijdens load/infer/encode,
laat resultaat, retrieval_pending, onbekende betaalde uitkomst, opname/wakeword,
slaap/lock/apparaatverlies, playback/seek/mute/export, geschiedenis, prullenbak/
herstel en Chat/Artifacts-referenties. Audio moet vóór microfoonoverdracht werkelijk
pauzeren; geen autoplay of automatische hervatting. Controleer toegankelijkheid,
licht/donker, smalle vensters, meerdere schermen en reduced motion met echte UI.

## GitHub, updates en uiteindelijke oplevering

Hergebruik PR #2 en bestaande sync-/validatie-/releaseworkflows. Laat nieuwe
changes onafhankelijk reviewen. Commit en push kleine reviewbare wijzigingen naar
de fork. Houd gewichten, caches, binaries, secrets, opnames en gebruikersgegevens
buiten Git. Publiceer compacte, geanonimiseerde meet-/testreceipts en documentatie.

De eigenaar heeft pushen en een normale merge naar main na geslaagde gates al
geautoriseerd. Controleer onmiddellijk vooraf de actuele PR-head, main-base,
conflicten en alle verplichte checks op die exacte revisie. Merge nooit met een
rode/ontbrekende/verouderde gate; geen history rewrite. De twee genoemde testfouten
moeten onderzocht zijn, niet verborgen door een toevallig groene herhaling.

Behoud `io.github.charafchnioune.nativ`, beide eigen Sparklefeeds en de bestaande
publieke sleutel; geen officiële upstreambinary die de custom features vervangt.
De privésleutel uit de Sleutelhanger van de vorige Mac staat terecht NIET in Git.
Genereer niet stil een vervangende update-identiteit. Veilige migratie van eigen
credentials/signingidentity vereist de eigenaar; nooit sleutelmateriaal in chat.

Developer ID, notarisation/stapling, beschermde GitHub-omgevingen/repositoryregels
en een echte ondertekende oud-naar-nieuw-Sparkle-upgrade blijven afzonderlijke
releasegates. Test behoud van bestaande Chat-, Images-, Translate- en mediadata.
Publiceer geen release zonder afzonderlijke toestemming. Upstreamsync blijft
normale mergekandidaten en verplichte regressies gebruiken; geïmporteerde
workflows/privileged scripts moeten vóór kandidaatpush gereviewd zijn.

Lever werkende geverifieerde code, bijgewerkte documentatie, exacte commit/PR/merge,
model/runtimepins, daadwerkelijke aantallen en prestaties, resterende externe
gates en reproduceerbare teststappen. Scheid mocks, codecproeven en echte modellen.
Ruim alleen bewezen inactieve buildproducten op en behoud één kandidaat plus
relevant bewijs. Behoud daarnaast de actieve bestaande app (op de vorige Mac
`FinalReviewed`), model-/Hugging Face-caches, gebruikersdata, Keychain-credentials,
originele testaudio en volledige XCResult-/CI-receipts. Verwijder deze niet als
generieke cleanup.

Begin nu met actuele repository/CI-inspectie, herstel de open blokkade en voer
daarná de echte modelkwalificatie en integratie op de M3 uit. Ga zelfstandig door
met alles waarvoor de benodigde hardware, rechten en middelen beschikbaar zijn.

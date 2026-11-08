# Technische duurproef van Live Translate

Deze proef meet de lokale LFM3-runtime en het loopbacktransport met twee bestaande, originele synthetische opnames. Zij kwalificeert geen taalrichting, stem of hoorbare latency. Een technisch voltooide turn kan een inhoudelijk verkeerde vertaling bevatten. De kwaliteitsvolgorde blijft LFM3 direct, dezelfde Omni in twee passes, vervolgens een expliciet gekozen alternatief; geen van deze metingen maakt Apple de hoofdroute.

## Reproduceren

Voer dit uit vanuit de repository, na de geverifieerde runtime- en modelvoorbereiding. De WAV-bestanden moeten al bestaan; de harness maakt geen stemopnames, opent geen microfoon en speelt niets af.

```sh
build/lfm-realtime/venv/bin/python -m pip install -r scripts/benchmarks/live_translation/requirements.txt
python3 -m unittest discover -s scripts/tests -p test_translation_endurance.py -v
build/lfm-realtime/venv/bin/python scripts/benchmarks/live_translation/endurance.py \
  --output build/lfm-realtime/endurance/NEW-UNIQUE-RUN \
  --duration 1800 --min-turns 100 --cold-starts 10 --cancel-turns 5 \
  --concurrent-activity 'Beschrijf de daadwerkelijk aanwezige achtergrondbelasting'
```

De standaardfixturemap is `build/lfm-realtime/probes/q8-fixed`. De Nederlandse bronzin luidt: “De afspraak is om half vier, niet om vier uur.” De Engelse bronzin luidt: “Please book two seats for Friday, not for Thursday.” Beide zijn eerder synthetisch gemaakt met Xander/Samantha als **bronmateriaal**. Zij zijn geen test van Apple als uitvoerstem en vervangen de zestig nog door mensen in te spreken testzinnen niet. Tijdens deze duurproef wordt geen Apple TTS aangeroepen.

De uitvoermap moet nieuw zijn. `summary.json` wordt atomisch bijgewerkt; `turns.jsonl`, `cold-starts.jsonl` en `memory.jsonl` bevatten de ruwe meetobservaties. Alleen de vertaaltekst van dit expliciete synthetische bronmateriaal wordt bewaard. Gegenereerde PCM wordt incrementeel gehasht/gemeten en weggegooid; geen volledige audio wordt opgeslagen. Gebruik deze diagnostische harness niet voor persoonlijke opnames.

## Wat de klok wel en niet meet

- Iedere turn krijgt een nieuwe WebSocket-context op dezelfde warme helper. De helper blijft tijdens de duurfase resident; er wordt niet per turn opnieuw geladen. NL→EN direct, EN→NL direct, NL→EN twee-pass en EN→NL twee-pass wisselen elkaar af.
- De bron wordt in frames van 20 ms op echte spreeksnelheid verstuurd. De laatste frameduur verstrijkt vóór `input_audio_buffer.commit`. Het monotone tijdstip net vóór deze commit is het nulpunt. Verzendvertraging van de input wordt afzonderlijk geregistreerd.
- `first_text_seconds` is de aankomst van de eerste tekstdelta; dit is geen gecommitteerde caption en geen visuele schermmeting. `first_audio_seconds` is de aankomst van de eerste PCM-data, ook als die uit stilte bestaat. `first_nonzero_pcm_seconds` is de aankomst van de eerste chunk met een genormaliseerd sample groter dan 0,0001 in absolute waarde. Ook die laatste waarde is **geen akoestisch begin**.
- Twee-pass sluit eerst de realtime-socket en vraagt daarna `/tts` voor de werkelijk ontvangen vertaling aan. De gehele commit→PCM-tijd telt mee. De extra TTS-aanvraag→eerste-PCM-tijd blijft afzonderlijk beschikbaar.
- De tien koude starts zijn **nieuwe helperprocessen met modellading**, met behoud van de OS-bestandscache. Het zijn geen tien herstarts van de Mac of gewiste schijfcaches. Bij tien waarden worden geen p95-claims gedaan.
- De vijf onderbrekingsproeven meten cancel-verzenden→lokale WebSocket-sluiting. Zij bewijzen geen moment waarop het model intern stopt, geen wachtrij-flush in AVFoundation en geen stop→hoorbare-stilte. Zij worden uitgesloten van de warme succesmetingen.
- Direct en twee-pass worden niet samengevoegd tot één latencyverdeling. Alleen volledig technisch geslaagde turns tellen mee voor de verdeling; fouten blijven zichtbaar in de noemer en maken de runstatus `failed`. p50 is de mediaan, p95 de nearest-rankwaarde `ceil(0.95*n)`; beide worden pas vanaf honderd geldige observaties **in dezelfde groep** gerapporteerd. Kleinere groepen tonen aantal, minimum, mediaan en maximum.

Deze Python-harness verifieert niet de Swift-hostwachtrijen, microfoonoverdracht, VAD, playback, schermweergave, luidspreker-/hoofdtelefoonroutes of systeemaudio. Die hebben afzonderlijke tests en praktijkacceptatie nodig. De doelen p50≤800 ms/p95≤1500 ms voor echte audio, captions p95≤1000 ms en stop→stilte≤150 ms kunnen hiermee niet worden afgevinkt.

## Reproduceerbare identiteit en begrenzing

De helper is de arm64/Metal-build van llama.cpp `v0.9.0`, commit `cd959bae99ff4bed22bef2604f45241c09bbb8c8`, inclusief de vastgelegde Origin-beveiligingspatch. De test gebruikt officiële Q8_0-gewichten en de Q8-projector van `LiquidAI/LFM3-Omni-2B-GGUF`, revisie `d508b88f08a5b4286f2d2805a6a8d69a0ff44c72`. Runtime-, model-, projector-, fixture- en harnesshashes worden in de uitvoer vastgelegd; afwijkende artifacthashes stoppen de proef vóór modellading.

De helper gebruikt dezelfde interpreterinstructies als de app, lege tools, `--reasoning off`, context 4096, één slot en maximaal 512 uitvoertokens. Realtime-uitvoer is PCM16; `/tts` is FLOAT32 met de werkelijk ontvangen formaatmetadata. De niet-deterministische modelgeneratie wordt niet als vaste reproductie van identieke vertaaltekst voorgesteld.

Het proces bindt uitsluitend op een door het OS gekozen loopbackpoort. Een willekeurige bearercredential leeft alleen in het eigen procesmilieu/geheugen; clients gebruiken geen proxy. De harness stopt uitsluitend zijn eigen helper, met begrensde teardown. Invoer is maximaal twaalf seconden per turn; uitvoer wordt incrementeel verwerkt en bij meer dan twaalf seconden afgewezen. De harness bewaart geen onbeperkte audiowachtrij. Een fout, timeout of onvolledige turn is zichtbaar en wordt niet stilzwijgend als snelle geslaagde observatie geteld.

Iedere seconde wordt `kern.memorystatus_vm_pressure_level` bemonsterd. OS-critical (waarde 4) of meer dan 2048 MiB extra **systeembrede** swap ten opzichte van de vooraf gemeten baseline beëindigt de eigen helper. `memory_pressure -Q`-vrijepercentages worden niet als OS-critical geïnterpreteerd. Proces-RSS is een deelmeting en omvat niet noodzakelijk alle Metal-/unified-memorykosten. Bestaande swap en andere apps worden niet aan LFM3 toegeschreven. Een run op de aanwezige M5 met 16 GB is geen uitspraak over alle 16 GB-Macs en geen meting op een 128 GB-Mac.

## Resultaten

De run van 8 november 2026, 12:36:13–12:43:24 UTC, is **afgebroken door de geheugenbeveiliging**. Run-ID: `7f71bee6-4f46-4c18-82c0-9f419a8eb3aa`. De tien proceskoude starts zijn voltooid; de warme fase duurde 412,966 seconden en voltooide 38 transportturns. Honderd warme metingen en dertig minuten zijn **niet behaald**. Er is geen menselijke taal- of stemkwalificatie en er worden geen p50/p95-claims gedaan.

Het compacte, reviewbare bewijs staat in [`endurance-evidence.json`](../../scripts/benchmarks/live_translation/endurance-evidence.json), inclusief alle 38 turns, afzonderlijke tekstdelta-/PCM-/signaalmetingen, de tien starttijden, 362 geheugensamples, originele uitvoervarianten en hashes van de ruwe bestanden. De lokale volledige artefacten staan onder `build/lfm-realtime/endurance/full-20261108-a`. De gemeten harnessversie is daar als `endurance-measured.py` bewaard en tegen de tijdens de run vastgelegde SHA gecontroleerd. De eerdere smoke is een afzonderlijk cohort en is niet bij de warme resultaten opgeteld.

| Transportmeting vanaf inputcommit | Direct, n=20 | Twee-pass, n=18 |
| --- | ---: | ---: |
| Eerste tekstdelta, mediaan | 0,250 s | 0,249 s |
| Eerste PCM-data, mediaan | 0,625 s | 2,261 s |
| Eerste PCM-data, minimum–maximum | 0,238–1,425 s | 1,487–3,272 s |
| Eerste chunk met signaal boven 0,0001, mediaan | 0,867 s | 2,261 s |
| Eerste chunk met signaal boven 0,0001, maximum | 2,627 s | 3,272 s |
| Technisch voltooide turns / protocolfouten | 20 / 0 | 18 / 0 |

Deze waarden combineren binnen iedere mode de twee vaste zinnen; richtingen zijn daarnaast afzonderlijk in het bewijs uitgesplitst (direct tien per richting, twee-pass negen per richting). In alle 38 voltooide turns arriveerde audio vóór de response volledig gereed was. Dit bevestigt transportstreaming in deze harness, niet hoorbare realtimewerking of appwachtrijgedrag. De eerste directe PCM-data kon volledig stil zijn. De grootste geregistreerde input-schedulingvertraging was 252 ms, ondanks realtime pacing; daardoor is dit geen onbelaste referentiemeting.

De tien proceskoude ready-tijden lagen tussen 0,842 en 2,388 seconden, mediaan 1,195 seconden, met de OS-bestandscache behouden. De geplande vijf cancelproeven na de warme fase zijn niet bereikt. In de afzonderlijke smoke was er één cancel→WebSocket-sluiting van 1,065 seconden; deze waarde meet geen akoestische stilte en bewijst het 150 ms-stopdoel niet.

### Machine en afbreekreden

De gemeten machine was een Apple M5, `Mac17,3`, 17.179.869.184 bytes RAM (16 GiB), macOS 26.6 / 25G72. Python was 3.9.6; WebSocket-client 15.0.1. De helper-SHA was `360abd72ac928837ec91216a66d919e36abef8e2f38304c9f438f529ceeb6c80`. De exacte model- en projectorhashes staan in het bewijs en [`runtime-manifest.json`](../../ThirdParty/LFMRealtime/runtime-manifest.json).

Er liepen Nativ-build/tests en onafhankelijk daarvan Xcode-/Swift-compilers uit een andere workspace, naast andere apps. Die externe processen zijn niet gewijzigd. De baseline had al 18.990,62 MiB systeembrede swap. De hoogste gemeten waarde werd 21.202,56 MiB: +2.211,94 MiB, boven de onveranderde limiet van +2.048 MiB. Daarom stopte de guard de eigen helper. De hoogste bemonsterde OS-pressurewaarde was **2 (warning), niet 4 (critical)**. De hoogste helper-RSS was 2.595.225.600 bytes, circa 2,60 GB / 2,42 GiB. Dit is geen totale unified-memorymeting. De gegevens wijzen niet uit welk deel van de extra systeemswap door de helper versus de concurrerende workloads ontstond; zij rechtvaardigen geen algemeen oordeel over alle 16 GB-Macs. Een 128 GB-Mac is niet gemeten.

### Betekenis en teardown

De werkelijk ontvangen tekst laat opnieuw blokkades voor kwalificatie zien. Alle tien directe NL→EN-turns maakten “half vier” tot “half past four”. Alle negen twee-pass NL→EN-turns maakten dezelfde tijdfout en veranderden bovendien “afspraak” in “pickup”. Alle negen twee-pass EN→NL-turns bleven Engels. Vier directe EN→NL-turns veranderden “Thursday” in “dinsdag”. Het bewijs bewaart de overige varianten letterlijk; er is geen percentage menselijke betekenis- of stemkwaliteit berekend en de hoorbare uitvoer is niet beluisterd.

De helper verdween aantoonbaar na cleanup, maar eindigde met `SIGABRT` (exitcode -6), dus de run krijgt geen claim van normale shutdown. Het eigen crashrapport toont Metal-resourcecleanup via de upstream-handler voor een tweede interrupt. De benchmarkguard stuurde SIGTERM en de `finally`-cleanup kon direct een tweede SIGTERM sturen. De gepinde upstream forceert bij zo'n tweede signaal `exit`, terwijl Metal nog resources kan hebben. Dit is in de **benchmarkharness** hersteld met gedeelde, idempotente beëindiging: guard en cleanup sturen samen maximaal één SIGTERM naar hun eigen proces. De regressietest is groen; een nieuwe echte modelrun na deze correctie is nog niet uitgevoerd. Het gemeten resultaat en zijn oorspronkelijke harnesshash blijven ongewijzigd als afgebroken proef bewaard.

Een eventuele tweede duurproef moet een nieuw cohort krijgen na aantoonbaar stabielere achtergrondbelasting. De druk- en swapgrenzen mogen niet worden verruimd en een nieuwe baseline mag deze mislukte poging niet verbergen.

### Tweede poging: niet gestart na baselinecontrole

Na afronding van de native build/tests en het stoppen van de previewserver is op 8 november 2026 van 13:38:55 tot 13:39:55 UTC één aparte uitgangsmeting uitgevoerd. Er is **geen tweede modelrun gestart**. De voorgenomen tweede run had 1800 seconden, minimaal 200 warme turns en tien proceskoude starts moeten omvatten, met dezelfde swap-/criticalguards. De eerste mislukte run is niet vervangen of samengevoegd.

De vooraf vastgelegde startcriteria waren: minstens zestig seconden meten; iedere sample OS-pressure 1; swaprange maximaal 128 MiB; absolute nettoverandering maximaal 64 MiB; geen sample boven de oorspronkelijke 18.990,62 MiB-baseline. De read-only observatie duurde 60,075 seconden en leverde 56 samples. **Alle 56 hadden OS-pressure 2 (warning)**. Swap daalde van 18.262,94 naar 18.158,94 MiB, een nettoverandering van −104 MiB. De swaprange en oorspronkelijke bovengrens voldeden, maar normale druk en nettostabiliteit niet. Er waren tijdens deze uitgangsmeting geen xcodebuild-, Swift- of clang-processen zichtbaar. Andere apps bleven ongemoeid.

Het afzonderlijke bewijs staat in [`endurance-retry-preflight.json`](../../scripts/benchmarks/live_translation/endurance-retry-preflight.json), inclusief de volledige uitgangsreeks, criteria, observerhash en hash van het ongewijzigde eerste bewijs. De exact gebruikte read-only observer staat in [`observe_baseline.py`](../../scripts/benchmarks/live_translation/observe_baseline.py). Deze start nooit een model. Herhalen kan met een nieuwe uitvoerbestandsnaam en dezelfde expliciete referentie; voor deze oplevering is geen nieuwe uitgangsmeting of modelrun uitgevoerd.

Het behaalde resultaat blijft dus tien koude processtarts, 38 warme transportturns en een na circa zeven minuten afgebroken run. Honderd warme observaties per mode, dertig minuten duurproef, menselijke kwalificatie en akoestische acceptatie blijven open. Er is nog steeds geen echte 128 GB-meting.

## Harnesscontrole

Acht deterministische tests behandelen correcte mediaan/nearest-rank-p95, het uitsluiten maar wel meetellen van fouten en onderbrekingen, het weigeren van incomplete/afgebroken succesclaims, OS-pressure/swapparsing, onvolledige poortregels, over HTTP gesplitste FLOAT32-samples, stille eerste PCM-chunks en precies één beëindigingssignaal bij guard plus cleanup. De regressies zijn eerst rood waargenomen en daarna groen uitgevoerd. Deze tests laden geen model. De oorspronkelijke runtimeproeven en het onafhankelijke audio/core-reviewrapport blijven aparte bewijsstukken.

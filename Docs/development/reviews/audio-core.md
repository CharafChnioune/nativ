# Independent review — session/audio/provider transport

Reviewer: review_audio_core. Reviewed Tasks2/3/4 and host integration as they existed on2026-11-08; no commit/push or app Xcode build was performed by this worker. Root owns final whole-tree builds, host wiring and human qualification.

## Verified findings and corrections

1. **Output transport could exceed two seconds.** Provider buffers were event-count bounded, but the core allowed128events and up to5seconds perchunk. Three one-second chunks stayed queued with no failure. `core-review-red.log` reproduced this. A single `TranslationAudioTransportBudget` now follows each unique PCM payload through raw HTTP `/tts`, speech synthesis, provider and core. Admission is atomic by duration, repeated handoffs do not double-count, and consumed chunks cannot reenter. Realtime batches reserve their complete PCM duration before yielding pieces. Generic injected providers are defensively admitted at the core boundary. Output transport is capped at2seconds; the separate playback queue stays5seconds. JSON/base64 framing retains its independent wire byte limit and oversized realtime PCM batches are rejected. Whole-phrase batch synthesis is a separately disclosed, finite result buffer, not a streaming claim.

2. **Recoverable errors were tagged with an obsolete generation.** `failInterval` emitted failure before invalidating generation; a correctly guarded host would discard the error and could continue showing Listening. The regression reproduced generation0event versus generation1snapshot. Failure is now emitted after invalidation, before the paused state event. Late old text/audio remains rejected.

3. **Failed complete source input was not retryable.** Failure previously erased all retry audio; the public retry operation only accepted running state. A complete, committed source segment can now be retained for an explicit retry after failure, with fresh backend context and a new turn ID. Partial input must be repeated. Snapshot `canRetry` reports actual availability and expires using an injected monotonic `TranslationClock`; expiry emits state. Stop/interruption still clear retry audio, and a retained segment expires after at most30seconds. Only one retry segment remains resident.

4. **Same-owner reentrancy bypassed actual passive microphone teardown.** While the first foreground acquisition awaited wake-word suspension, a second disjoint resource request by the same owner saw the boolean suspension flag and returned early. The new test failed before the fix (`audio-review-red.log`). All foreground acquisitions now await the same physical-teardown task before any grant. Cancellation and stale release behavior remain tested.

5. **Playback had no device-loss recovery.** Added a route monitor that pins the default output for a session, checks selected-device liveness/sample-rate and default-route changes, and synchronously flushes/relinquishes playback before reporting `onFailure`. It never silently changes headphone output to speakers. Engine configuration notifications are scoped by observer/request generation and ignored for intentional graph reconfiguration; an unexpected stopped engine fails visibly. A fake route source verifies lease release and that stale notifications cannot stop the next session. Real unplug/route behavior still needs physical-device testing.

## Root host findings communicated

- `receive` must `defer { event.acknowledgeAudioDelivery() }` before generation/mute guards, so discarded audio releases its admission too. Root has integrated this.
- Core `.paused`/failure must stop host capture visibly while preserving an available retry. Root has integrated paused/error handling.
- Segmenter reset resets its sequence; speaker mode capture restarts previously reused sequence0 against the core's monotonic input guard. Root now owns a monotonic per-session host input sequence across capture epochs.
- `turnCompleted` must find the completed snapshot row by `event.turnID`, not snapshot's last row: a fast provider can finish a later turn before the host reads the earlier completion. Root was notified to correct this.
- Root must wire `TranslationAudioPlayback.onFailure` to its visible failure/teardown action.
- Chatterbox returns a complete WAV phrase. Its generated result cannot honestly be covered by a2second streaming-transport claim. Root/cascade owner agreed to disclose the separate batch result, cap playable phrases to12seconds and reject longer output; no streaming label.

## API additions

- `TranslationConfiguration.audioTransportBudget` is shared across all output adapters.
- `TranslationAudioChunk.admitted(to:)` before provider buffering; `.acknowledgeDelivery()` after transfer to bounded playback or discard.
- `TranslationEvent.acknowledgeAudioDelivery()` is the convenient host acknowledgement; idempotent across copied event values.
- `LFM3SpeechSynthesizer.stream(text:language:budget:)` accepts the same budget. `LFMSpeechTransport.stream(_:budget:)` returns admitted rawPCM chunks so the HTTP queue does not sit outside the duration limit.
- `TranslationSpeechRenderer.synthesize(text:language:budget:)`; cascade forwards the shared budget, and host renderers admit before yielding.
- `TranslationSession(backend:clock:)`; snapshot `canRetry`; retry from paused failure resets context before sending retained input.
- `TranslationAudioPlayback(routeMonitor:audioSessions:)` injection for route/lease tests; `onFailure` reports a synchronously flushed route failure.

## Verification

- Core duration/error regressions were red before changes; later complete suite passed29core Swift Testing tests plus the existing24XCTest protocol/cascade/WAV tests (53total). Exact final output: `build/validation/core-review-final.log`.
- Native audio harness runs real production AVFoundation adapters and vendored VAD, with only explicit device/route boundary fakes. Final50tests passed, zero failures; `build/validation/audio-review-routes.log`. Includes the reproduced same-owner teardown race and two route recovery tests. The scratch harness needed the newly introduced NativBuildIdentity source linked to reflect root's fork-storage changes.
- The modified streaming transports were also exercised against the real pinned Q8helper and projector: `NATIV_LFM_TEST_ROOT=.../build/lfm-realtime swift test --package-path build/RuntimeHostChecks --jobs2`. All7host tests passed. Both directPCM16 and two-passFLOAT32 returned real audio with the shared duration admissions. Owned helper stopped; no microphone or output playback opened. `build/validation/runtime-review-budget.log`.
- One technical observation per mode in that rerun: direct172800bytes, commit-to-first-received-audio0.6999165s; two-pass353280bytes,1.941621125s. These are transport observations, not acoustic latency, percentiles or voice/translation qualification.

## Remaining acceptance gates

Final combined app/CI checks, independent final patch review, hardware microphone/unplug/default-route tests, audible stop-to-silence, multi-screen/accessibility UI, human bilingual fidelity/prosody/emotional-intent acceptance,100warm/10cold statistics and30minute soak are not established by this review. No model/voice/pair became qualified. No full-duplex or acoustic AEC claim is justified.

## Aanvullende testtriage — 2026-11-08 14:07

De finale Xcode-run vond één fout in `queuesOneWaitingTurnUntilCompletion`. De productiebron van de canonieke repository en de Xcode-testsnapshot was identiek (SHA256 van `TranslationSession.swift`: `6f80c5f03e2c88942d96eec6e4916e8cdb42edf8fcefc3a2fd81c0397a2175df`). De fout was ook in SwiftPM onmiddellijk reproduceerbaar: `core-queue-scheduling-before.log`.

De test wachtte honderd keer `Task.yield()`, maar daarmee is de asynchrone keten stop → start → send → commit niet gegarandeerd voltooid. Een tijdelijke diagnose registreerde na die yields één commit en één start, en daarna twee commits zodra het concrete commitmoment was bereikt. De oorspronkelijke volgordeassertie slaagde daarna; honderd diagnostische herhalingen waren groen (`core-queue-scheduling-diagnostic.log`, diagnose op regel 44). Er is geen productiefout aangetoond en de productiecode is ongewijzigd.

Alleen `Tests/NativTranslationKitTests/TranslationCoreTests.swift` veranderde: de betreffende test wacht nu op het werkelijk bereiken van twee backendcommits, begrensd door een monotone deadline van twee seconden. De exacte volgordeassertie blijft aanwezig. Er is geen vaste sleep toegevoegd.

- 1.000 herhalingen van deze regressie geslaagd: `build/validation/core-queue-scheduling-after.log`.
- Volledige kit: 24 XCTest + 29 Swift Testing = 53 geslaagd: `build/validation/core-review-scheduling-final.log`.
- Strict swift-format lint geslaagd. Definitieve testfile-SHA256: `4263b0f8ac582dbe58ef892dcb853cf927272005fadcef6f73660975141a79b2`.

De rebuild in Desktop liep vóór compilatie vast in `getcwd/open`; alleen de eigen compilerprocessen zijn beëindigd. De tests hierboven draaiden met `--jobs 2` op een exacte minimale kopie in een tijdelijke validatiemap buiten Desktop. Er zijn geen privacyinstellingen aangepast, geen Xcode-builds gestart en geen modellen geladen. Root moet voor de native hertest uitsluitend de gewijzigde testfile naar de bestaande Xcode-testsnapshot verversen.

## Baseline PDF-testtriage — 2026-11-08 14:13

De volledige native regressierun vond twee assertiefouten in `ChatDocumentContextBuilderTests.testChangedPDFExcerptsAndFittingPreserveSavedCompaction`. Dit is een achtergebleven upstream-testverwachting, geen aangetoonde productiefout. De test uit commit `0c2b073f2` (14 oktober) verwachtte verse documentcontext als laatste `input`-bericht. Upstreamcommit `862b03582938c14b8b7970b0c2b325d2496bb4e4` (28 oktober, PR #780) verplaatste tijdelijke context expliciet naar het top-level veld `transient_context`. De betreffende PDF-test werd daarbij niet bijgewerkt. Beide versies zijn zo aanwezig in oorspronkelijke baseline `5cb79ed65659414774745c1331cce08397d16055`. Andere bestaande `ChatCompactionTests` controleren al het nieuwe contract.

Een kleine SwiftPM-harness in een tijdelijke validatiemap buiten Desktop gebruikt rechtstreeks uit baseline 5cb geëxporteerde ServerKit-bronnen en `ChatCompactionState`. De proef herstelt een opgeslagen capsule, voegt de assistant/user-tail toe en controleert gewijzigde, verkorte en afwezige context. Met de oude laatste-berichtassertie reproduceerde hij precies twee fouten (`build/validation/pdf-context-baseline-red.log`); met de bestaande `transient_context`-afspraak slaagde dezelfde proef (`pdf-context-baseline-green.log`). Geen modellen of netwerkrequests zijn uitgevoerd.

Alleen `Tests/NativTests/ChatDocumentContextBuilderTests.swift` is aangepast: het test nu het actuele veld, vergelijkt de volledige `input` met capsule plus tail en vereist afwezigheid van `transient_context` wanneer geen fragmenten beschikbaar zijn. De eerdere capsule-, fitting- en invalidatiecontroles blijven intact. `git diff --check` slaagt; testfile-SHA256 is `72299bc1febd85d8c67f2205c13069f06cf85f8290fc26385055c4d775e9703e`. Productiecode is ongewijzigd. Root moet deze ene testfile verversen en de daadwerkelijke native buildertest hertesten; de scratchproef bewijst het serialisatiecontract, niet de volledige documentextractie.

## Wakeword-routingtriage — 2026-11-08 14:21

De twee native timeouts in `testNoAllowedInputDrainsSpeechAndFinishesOnceBeforePausing` en `testCaptureFailurePreservesConfirmedSpeech` zijn exact gereproduceerd met de actuele productiecode in een kleine SwiftPM-harness (`wakeword-routing-before.log`: twee van vier routingtests falen). Met de baselineversies van `VoiceWakeWordMonitor`, `AudioInputLevelMonitor` en `VoiceAudioRecorder` slagen dezelfde vier tests (`wakeword-routing-baseline.log`).

Oorzaak: de testfixture injecteerde `AudioInputCaptureSession { capture }`. Na toevoeging van gedeeld audio-eigenaarschap levert die standaard een foregroundlease. De echte monitor maakt zijn sessie echter expliciet met `passiveListener: true`. Het vrijgeven van de onbedoelde foregroundlease in de test activeert de callback voor hervatten van passief luisteren; die roept `restart()` aan en invalideert de sessie-ID voordat `finishCaptureBeforeRestart()` de gedrainde spraak kan afleveren. De bestaande drain- en leasebarrières zelf hoeven hiervoor niet te veranderen.

Alleen de fixture in `Tests/NativTests/VoiceWakeWordTests.swift` is aangepast naar `AudioInputCaptureSession(passive: true, passiveListener: true)`. Dit volgt de productieconfiguratie. De timeout, assertions op behouden spraak, eenmalige aflevering en expliciete annulering blijven onveranderd. `VoiceWakeWordMonitor.swift` en alle andere productiecode zijn door deze triage ongewijzigd.

Verificatie tegen de actuele productiecode: alle vier routingtests elk vijf keer geslaagd, twintig uitvoeringen (`build/validation/wakeword-routing-after.log`). `git diff --check` slaagt. Exacte testfile-SHA256: `925c9289ab3887f09312b09553d8eabfe71b706ffa283c62b4ac192a147788f6`. Harness in een tijdelijke validatiemap buiten Desktop; SwiftPM `--jobs 2 --no-parallel`; echte capture/monitor/processorcode met de reeds bestaande geïnjecteerde microfoon- en detectorproef. Geen hardwaremicrofoon, modelrun of Xcode-build uitgevoerd. Root moet uitsluitend deze testfile verversen voor de gehele native hertest.


## Finale gerichte review — geheugen en providerkeuze

De actuele `TranslationResourceAssessment.swift`, de vier `TranslationResourceAssessmentTests` en de relevante beslispaden in `LiveTranslationCoordinator`, instellingen, providercatalogus en cascadefactory zijn alleen gelezen. Tijdens deze ronde zijn geen code, tests of modellen uitgevoerd of gewijzigd.

- De geheugenschatting gebruikt de fysieke capaciteit van de huidige Mac en een proportioneel planningsbudget van 80%. Er is geen vaste 16-GB-blokkade. Bij 20 GiB modelbestanden overschrijdt de 16-GiB-fixture het budget en de 128-GiB-fixture niet; beide mogen bij normale druk een expliciete laadpoging doen. De bestandsgrootteschatting wordt dus niet voorgesteld als gemeten resident geheugen of als bewezen ongeschiktheid.
- `TranslationHardwareSnapshot.current()` leest de actuele macOS-druk via `kern.memorystatus_vm_pressure_level`. Onbekende of mislukte uitlezing blijft `unknown`. Alleen `critical` verhindert starten; een kritieke dispatchmelding pauzeert de coordinator en stopt diens eigen Omni-runtime. Een laag aantal vrije pagina's, een modelnaam of het gewichtbestandsbudget vormt geen zelfstandige laadblokkade. De gedeelde MLX-runtime valt niet onder het eigenaarschap van die Omni-processcontroller; dit is geen claim dat alle geladen modellen in de app zijn vrijgegeven.
- De tests onderscheiden 16 en 128 GiB, een klein lokaal profiel, werkelijke kritieke druk op beide capaciteiten en ontbrekende meetgegevens. Deze vier tests staan als geslaagd in `build/validation/native-tests-regressions.log`; dat eerdere volledige testrapport bevatte nog de afzonderlijk onderzochte PDF- en wakeword-fouten. De nieuwe volledige native hertest loopt bij de integrator en wordt hier niet alvast als geslaagd gerapporteerd.
- De geselecteerde Omni-precisie gaat rechtstreeks naar modelvoorbereiding. De cascade zoekt exact de gekozen herkenner, vertaler en renderer; ontbrekende modellen of niet-ondersteunde adapterfamilies leveren een zichtbare fout. Apple wordt alleen via de expliciete aanvullende rendererkeuze aangemaakt. Er is geen automatische routewisseling naar Apple, cloud, andere gewichten of een ander model gevonden.
- LFM3 direct en daarna dezelfde Omni in twee passes blijven de evaluatievolgorde. De catalogus houdt `qualifiedDefault` leeg en de UI vereist expliciete acceptatie van de experimentele route. Een gewijzigde instelling start een nieuwe context pas na Resume. De totale cascadevoetafdruk blijft zichtbaar onbekend zolang die niet voor het complete profiel is vastgesteld; gedeeltelijke modelgewichten worden niet als gecombineerde meting gepresenteerd.
- Eerder gemelde hostpunten zijn in de actuele coordinator aanwezig: audio-acknowledgement vóór stale/mute-guards, een doorlopende inputvolgorde binnen de sessie, transcriptselectie op de concrete voltooide turn-ID, zichtbare playbackfouten en behoud van de kern bij herstelbare fouten voor de begrensde retry.

Reviewstatus: geen nieuwe blokkerende fout gevonden binnen deze gerichte codecontrole. De eerder bewezen regressies en testcorrecties staan hierboven met hun eigen bewijs. Dit is geen vervanging voor de finale gecombineerde native testrun, hardwaretests of menselijke taal- en stemkwalificatie. Het openbare rapport bevat alle actuele reviewbevindingen; lokale machinepaden zijn verwijderd. Lognamen verwijzen naar lokale/CI-validatieartefacten en zijn geen gepubliceerde links.

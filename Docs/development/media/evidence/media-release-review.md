# Onafhankelijke release-, upstream- en upgradecontrole

Datum: 8 november 2026. Scope: fork workflows, release/update-identiteit, concrete appresources, native testmembership, opslagupgrade en de gedeelde Swift-client. Bronbestanden met SHA-256 staan in `media-release-review-evidence.json`. Dit is een lokale beoordeling van de dirty implementatie, geen vrijgave, ondertekende update of bewijs van gepubliceerde CI.

## Bevindingen en uitgevoerde correcties

1. **Bevestigd, opgelost: releasecontrole accepteerde onvolledige media-app.** De oude `validate_bundle` accepteerde een synthetische app met correcte Info.plists, extensies en LFM-helper zonder Python, Music/Video-pakketten of codecs. `scripts/fork_release.py` vereist nu alle drie pakketbomen, alle vier runtime-resourcebomen, beide serveroverlays, uitvoerbare interpreter/launcher en verplichte managed codecs. De volledige membership/content wordt met de vertrouwde bron vergeleken; ontbrekende providers, gewijzigde resources en ontsnappende symlinks falen. FFmpeg/ffprobe moeten overeenkomen met actuele receipthashes; receiptidentiteit, sourcepins, manifesthash, builderhash en media-qualification zijn verplicht, ook zonder lokale `dist/codec-runtime`.

   `bundle --verify-imports` draait echte lichte imports met de ingepakte interpreter, `-I -B`, een tijdelijk werkpad buiten de checkout en een minimale environment. Alleen de unsigned workflow gebruikt deze optie. De publisher doet statische controles en voert geen kandidaatcode uit met signing credentials. Zeven nieuwe synthetische resource-regressies omvatten de oorspronkelijk geaccepteerde identity-only app, ontbrekende/gewijzigde bestanden, corrupte codecs/provenance, interpreterescape en geïsoleerde importomgeving. De fixtures bevatten expres fake executables; zij claimen geen echte app of codecwerking.

2. **Bevestigd, opgelost: uploadantwoord had geen geheugengrens.** `NativGenerationClient.uploadInput` gebruikte `URLSession.upload(for:)`, dat het volledige antwoord als Data verzamelt. De nieuwe per-task `URLSessionDataDelegate` begrenst declared en streaming response op 16 MiB, weigert redirects en ondersteunt taskcancellation. De multipart-stagingfile heeft nu permissies 0600. Een echte URLProtocol-regressie test beide oversizevarianten en een succesvolle upload met bearer/storeheaders. Een negative-controlkopie met de oude uploadroute faalt aantoonbaar; de huidige code slaagt.

3. **Ontbrekend upgradebewijs gedeeltelijk ingevuld.** `test_generation_upgrade.py` introduceert Generations naast bestaande Chat/Images-JSON en Translate-preferences-Data en bewaakt identieke bytes. Een schema-1 store wordt in verse serviceinstanties heropend met dezelfde store/job/asset/ref-identiteiten. Live references en released tombstones blijven behouden, Trash overleeft heropenen, Restore behoudt originele SHA en pad, en een gewijzigde providerrevision blokkeert redispatch vóór een provider wordt geconstrueerd. Er wordt geen bestaand bestand verwijderd. Dit is een gesimuleerde opslagupgrade; native Codable-tests en een daadwerkelijke ondertekende Sparkle-installatie zijn afzonderlijke bewijslagen.

Geen verdere concrete releaseblocker gevonden binnen deze scope. De definitieve brongebonden appcontrole en onderstaande kwalificatiegates staan nog open.

## Uitgevoerde verificatie

- **104/104 Python-tests groen**, geen skips: fork release, upstream sync, macOS release, media packaging, XCTest-evidencechecker, Sparkle feed/setup en de twee upgradesimulaties. Log: `media-release-review-tests.log`.
- **7/7 echte XCTest-clienttests groen** in een geïsoleerde SwiftPM-harness met kopieën van de actuele transport/types/testbestanden. Geen andere build in de door root beheerde DerivedData. Log: `client-upload-probe.log`. Oude uploadroute: `client-upload-probe-red.log`, één verwachte fout. Swift 6 standalone typecheck van client/types eveneens geslaagd.
- `python3 scripts/fork_release.py sources` geslaagd.
- Het daadwerkelijke `NativTests` PBXSourcesBuildPhase is onderzocht: **373 sources**, inclusief GenerationClient/Persistence/Presentation/ComputeLease-tests en de nieuwe feature/shared modules. De CI voert het volledige target uit en vereist daarnaast de concrete generatie-testklassen via `verify_translation_test_results.py`. Membership wordt hier niet gelijkgesteld aan een geslaagde laatste integrale Xcode-run; root voert die na freeze uit.
- `git ls-files` vond geen getrackte safetensors/GGUF/CKPT/PT-modelgewichten, P12/P8/PEM/KEY-bestanden, `.env` of lokale signingconfig. Build/dist en lokale signingconfig zijn genegeerd. Er is geen geheime environment of Keychaininhoud afgedrukt.

## Concrete checkpoint-app

Gecontroleerd: `build/NativeGenerationDerivedData/Build/Products/Debug/Nativ.app`. Dit is checkpoint `e22f7b9333a4ff7437bd81879454f050cbb3c6b9-dirty`, versie 1.0.0/build 1. De app heeft de forknamespace `io.github.charafchnioune.nativ`; drie eigen frameworkidentiteiten en beide eigen extensiebindings zijn aanwezig. Stable/preview feeds wijzen uitsluitend naar `CharafChnioune/nativ`; de eigen Sparkle Ed25519-public key is aanwezig met `SURequireSignedFeed=true` en `SUVerifyUpdateBeforeExtraction=true`.

De echte ingepakte Python importeerde buiten de checkout succesvol `nativ_generation`, Music en Video, met 7 Music- en 9 Video-profielen. Modulepaden resolveerden binnen de app. Beide codecbytes kwamen overeen met hun ingepakte hashes. Log: `media-release-checkpoint-imports.log`. Het LFMRealtime-helperbestand is aanwezig. Deze Debug-app heeft een ad-hoc linker signature, geen Developer ID/team en geen productie-resource seal; dit is geen ondertekend distributieartefact.

**De nieuwe bronvergelijking weigert dit checkpoint terecht:** `Packaged overlay differs: nativ_generation`. De bron is sinds de build gewijzigd. Dit is geen claim dat de actuele bron correct in deze app is opgenomen. Na de laatste commit/build moeten `fork_release.py bundle ... --sha <exact commit> --verify-imports` en de integrale native tests opnieuw slagen. Een dirty-revisionoverride is alleen gebruikt voor checkpointinspectie, nooit als releasegoedkeuring.

## Workflow- en updatebeoordeling

- `translation-ci.yml` gebruikt exacte head/base-validatie, vereiste Python/Swift/macOS-jobs, echte verplichte managed-codecbuild, appbuild en XCTest-evidence. De required aggregate gate wijst ontbrekende, overgeslagen, geannuleerde of verouderde resultaten af.
- Alleen `fork-release.yml` publiceert deze fork. De unsigned build en beschermde signing/publicatiestap zijn gescheiden; tag/main/exact gevalideerde commit worden opnieuw gecontroleerd. Signing tooling wordt vooraf geverifieerd, inherited signing/provisioning wordt geweigerd en bestaande releaseassets worden niet overschreven. Geërfde upstream release/dev/pages-workflows zijn voor `Neywa-Labs/nativ` begrensd en publiceren niet vanuit deze fork.
- Upstreamsync gebruikt immutable SHAs/baseline, een geïsoleerde tijdelijke merge, exact-head validatie, actuele main-rechecks en create-only branchpublicatie. Geen automatische merge of herschrijven van tags. Workflow/buildwijzigingen vereisen expliciete gereviewde patchidentiteit en een protected environment. Nieuwe native Music/Video-paden staan niet expliciet in `PROTECTED_PREFIXES`; alle integratie blijft handmatig gereviewd. Dit is een mogelijke latere beleidsuitbreiding, geen aanwezige automatische-mergefout.
- De updater valideert eigen feeds/key, signed-feedbeleid en fork-only updatearchives vóór starten. Sparkle 2 is aanwezig als updaterdependency. Ondertekende feed/ZIP-publicatie en echte update-installatie zijn hier niet uitgevoerd.

## Open gates, geen geslaagde claims

1. Finale officiële brongebonden build met alle resources en de volledige vereiste XCTest-run na de laatste wijzigingen; root beheert deze run.
2. Eigen Developer ID, hardened runtime/entitlements, notarization/stapling, Gatekeeper en Sparkle-archive/feedhandtekeningen van een echte release.
3. Werkelijke ondertekende upgrade van de prefeature-app naar Music/Video en daarna een volgende versie, met Chat/Images/Translate, bibliotheek, Trash/Restore en Keychain intact. De nieuwe fixturesimulatie vervangt deze niet.
4. Geen lokale modelinstallatie of inference op grotere hardware: operationele runtime-/modelkwalificatie, piek/unified-memory, langdurig thermisch gedrag en Translate/generatie resourcewissels op de ondersteunde apparaten blijven afzonderlijk vereist.
5. Geen betaalde cloudruns: echte accounts, regiobinding, providercontracten, cancellation/charges, retrieval en kwaliteitsacceptatie blijven kwalificatiegates. Experimentele profielen mogen daardoor niet als bewezen native/production-ready worden geadverteerd.

Geen release, signing, upload, push, merge of Git-mutatie uitgevoerd door deze reviewer. Alleen de expliciet toegewezen releasegate, clientcorrectie en regressietests zijn gewijzigd.

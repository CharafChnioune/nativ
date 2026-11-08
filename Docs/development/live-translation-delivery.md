# Live Translate — reviewbare developmentoplevering

Branch: `codex/live-translation`, [draft-PR #1](https://github.com/CharafChnioune/nativ/pull/1).
Fork: `CharafChnioune/nativ`; upstream: `Neywa-Labs/nativ`.
Er is niets gemerged of gepubliceerd als release.

De native appbuild bevat broncommit
`029258629ea8f91ee843734bc2e2bb776274e48b`. Latere commits met alleen documentatie
en bewijs veranderen die app niet. De volledige validatie van de actuele
PR-head staat bij de [PR-checks](https://github.com/CharafChnioune/nativ/pull/1/checks).

De lokaal gebouwde en met Apple Development ondertekende app staat op:

```text
/Users/charaf/Library/Developer/NativLiveTranslationPreview/FinalReviewed/Nativ.app
```

Make en deep/strict-signaturecontrole zijn geslaagd. De exacte app is zichtbaar
geopend. Whisper, Gemma en LFM3 zijn in de gewone modelcache gevonden; beide
voorbereidingsknoppen hebben hun verificatie voltooid. Twee vensters deelden de
taalrichting. De app is achtergelaten op LFM3 direct, Nederlands→Engels, zonder
actieve capture of chatserver en met experimentele toestemming uitgeschakeld.
[Bundle/UI-bewijs](translation-final-reviewed-bundle-evidence.json) en
[cachevoorbereiding](translation-final-app-cache-evidence.json) bevatten de details.

## Wat werkt en wat is gemeten

- Onafhankelijke STT-, LLM- en TTS-keuze; lokale cascade, native pagina/overlay,
  apparaatkeuze, onderbreking, gedeelde audioleases en aparte systeemaudiobron.
- LFM3 direct → dezelfde Omni in twee passes → expliciet gekozen alternatief
  blijft de voorkeursvolgorde. Apple TTS is uitsluitend een handmatige optie.
- De echte cascade Whisper large-v3-turbo → Gemma 4 E4B → LFM3-Omni Q8 heeft
  beide synthetische NL/EN-voorbeelden voltooid. De laatste doelteksten behielden
  half vier, twee plaatsen, vrijdag en de ontkenning. Eerste ontvangen PCM:
  **7,215/6,840 seconden**, inclusief sequentiële ladingen. Dit zijn twee losse
  observaties, geen akoestische latency of algemene nauwkeurigheidsscore.
- Bronbewuste controles blokkeren de geteste fouten in getallen, tijden, datums
  en negaties vóór cascade-TTS. De gemeten uitvoertaalfout is afzonderlijk
  aangepakt. Deze controles garanderen geen volledige semantische correctheid.
- De laatste review herstelde supervisoropruiming, gefragmenteerde poortdetectie
  en Whisper-taalclaims. **17/17** gerichte native regressies slagen; Python:
  **172 totaal, 171 geslaagd, één expliciete opt-in skip**. De CI-gate vereist
  achttien klassen en twaalf kritieke cases.

Een aanvullende CI-run op `ce2a838f` onthulde een timingrace in de bestaande
test voor audiobudget na contextrollover: de PR-run faalde één case terwijl
de onafhankelijke branch-run op dezelfde commit slaagde. De test wacht nu op
werkelijke backend-/sessiemijlpalen en forceert de rollover-tussentoestand.
De productiecode en budgetgrenzen zijn niet gewijzigd. De deterministische
RED/GREEN-proef en volledige SwiftPM- en native Kit-tests zijn vastgelegd in
[het synchronisatiebewijs](translation-core-test-synchronization-evidence.json).

De cascadeproef is op een M5 met 16 GiB uitgevoerd. Sequentiële en resident-modus
zijn expliciete keuzes; geen vaste limiet sluit 16- of 128-GB-Macs uit. Een
128-GB-Mac en andere modelcombinaties zijn niet doorgemeten. Per taak en concrete
modelvariant blijven eigen taal- en assetbeperkingen gelden.

## Bekende grenzen

**Directe en tweepass-LFM3-vertaling blijven ongekwalificeerd:** de actuele
Q8/Q4-proeven leveren tekst in de doeltaal, maar veranderen nog tijd en
boekingsintentie; Q4 verandert ook een dag. Zonder brontranscript kan de
bronbewuste guard deze fouten niet vergelijken. Er is geen verborgen fallback.

De Q8-duurproef voltooide **160 warme turns en tien proceskoude starts** en
stopte na **15m22s warme metingen** op de vaste systeemswapgrens. De vereiste
dertig minuten en vijf geplande onderbrekingsproeven zijn niet voltooid; er zijn
geen gekwalificeerde p50/p95- of akoestische stopmetingen. De globale swapgroei
wordt niet uitsluitend aan het model toegeschreven.

De eigenaar beoordeelde twee hoorbare MP3-voorbeelden met “goed”. Nieuwe
menselijke opnamen, dertig beoordeelde turns per richting, gesproken betekenis,
prosodie/emotie, actieve apparaat-/systeemaudio-/sleep-/lockproeven en volledige
duurkwalificatie blijven open. Andere talen erven geen kwalificatie.

## Updates en exacte pins

Eigen namespace, stabiele/preview-Sparkle-feeds en openbare sleutel zijn
geconfigureerd. De privésleutel blijft in Sleutelhanger. Acht echte ondertekenings-,
feed-, download- en sabotageproeven slagen. Gecontroleerde upstreamsync en een
afzonderlijke releasepublisher zijn voorbereid; de sync-/releaseworkflows worden pas actief
na integratie op de daarvoor bedoelde branch.

Developer ID, notarization, beschermde GitHub-credentials/environments en
repositoryregels blijven eigenaarsetup. Er is geen publieke update uitgebracht
en geen echte oud-naar-nieuw-installatie getest. De concrete stappen staan in
[forkonderhoud](fork-maintenance.md).

| Onderdeel | Gemeten pin |
| --- | --- |
| llama.cpp v0.9.0 | `cd959bae99ff4bed22bef2604f45241c09bbb8c8` |
| LFM3-Omni Q8/Q4 en Q8-projector | `d508b88f08a5b4286f2d2805a6a8d69a0ff44c72` |
| Whisper large-v3-turbo | `a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb` |
| Gemma 4 E4B 4bit | `475b9088d29754a3379866cf5aeb6b41acd313c2` |

Zie de [volledige acceptatiematrix](live-translation-acceptance.md),
[catalogus](translation-stage-catalog.md), [modelmanifest](../../ThirdParty/LFMRealtime/runtime-manifest.json),
[cascade-inhoud](translation-host-cascade-content-evidence.json),
[duurproef](translation-production-endurance.md) en
[Sparkle-bewijs](sparkle-signature-evidence.json) voor hashes, tests en grenzen.

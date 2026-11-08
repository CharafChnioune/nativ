# Onafhankelijke review van het cascadevervolg

Op 8 november 2026 heeft een afzonderlijke reviewer zonder overgenomen
gespreksgeschiedenis de vervolgwijziging tot `c249f990` onderzocht. De review
vond drie concrete fouten; ze zijn hersteld in `5202fa1d` en daarna opnieuw
door dezelfde reviewer op broncode gecontroleerd.

| Bevinding | Herstel en regressie |
| --- | --- |
| P1 — Swift kon de supervisor doden voordat deze zijn Python-child had opgeruimd. | Alleen de gebundelde C-supervisor escaleert en reapt zijn child. De Swift-shutdownbarrière blijft gesloten tot de supervisor afsluit. De test gebruikt de echte supervisor met een private TERM-negerende fixture en controleert beide PIDs en een gelijktijdige herstart. |
| P2 — Een afgebroken logregel kon een onvolledige poort als definitief vastleggen. | Readiness vereist een werkelijk ontvangen scheidingsteken na de volledige poort. Fragmenttests controleren beide onvolledige prefixes. |
| P2 — Whisper kreeg te ruime of verzonnen taalclaims. | De catalogus volgt native/Hugging Face-loaderprecedentie, onderscheidt 99/100 talen en weigert ontbrekende/onbekende vocabulairemetadata. |

De regressies faalden aantoonbaar vóór herstel. Daarna slaagden alle zeventien
gerichte native cases zonder skips. De vijf nieuwe cases zijn afzonderlijk
verplicht in de CI-bewijsgate; een bestaande groene klasse kan ontbrekende of
overgeslagen regressies niet maskeren. De acht gate-tests slagen. De volledige
Python-run telt 172 tests: 171 geslaagd, één expliciete opt-in skip.
[Exacte bronhashes, RED/GREEN-resultaten en loghashes](../translation-review-regressions-evidence.json)
leggen de bewijsgrens vast.

De reviewer vond bij de hercontrole geen resterende blocker in deze correcties.
Dit was broncodebeoordeling; de reviewer heeft de tests niet zelf herhaald.
De uitvoerende agent draaide de tests en de hoofdagent controleerde de
bron-/loghashes en het native xcresult. De modelmetingen blijven aan hun eigen
eerdere bronidentiteit gekoppeld. Menselijke stem-/betekenisbeoordeling,
hardwareproeven en distributiecredentials zijn geen afgerond resultaat van
deze review.

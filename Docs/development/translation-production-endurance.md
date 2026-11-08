# Productie-duurproef Q8: afgebroken op de swapgrens

De nieuwe Q8-duurproef van 8 november 2026 is **niet geslaagd**. De ongewijzigde
geheugenbewaking stopte de eigen helper na 922,103 seconden warme metingen
(15 minuten en 22 seconden). Er waren tien voltooide koude processtarts,
161 warme pogingen en 160 voltooide transportturns. De laatste poging werd
afgebroken door de guard. De geplande 30 minuten, minimaal 200 warme turns en
vijf onderbrekingsproeven zijn niet voltooid. Het
[meetbewijs](translation-production-endurance-evidence.json) bevat exacte pins,
commando-identiteit, teksten, uitkomsten, resourcewaarden en hashes van de ruwe logs.

De eerste twee minuutcontroles wezen de start af doordat bestaande systeemswap
nog daalde. Ze zijn bewaard. Na afzonderlijke read-only observaties voldeed een
nieuwe volledige controle wel: 60,038 seconden normale druk, 8 MiB swaprange,
−8 MiB nettoverandering en geen compilers. De oorspronkelijke grenzen van
128 MiB range en 64 MiB absolute nettoverandering zijn niet verruimd. De
productiedriver en het dynamisch geladen framework zijn voor en na de proef
gehasht en bleven ongewijzigd. De proef hergebruikte exact dezelfde twee
synthetische WAV-bestanden als de Q8/Q4-matrix en native cascadeproef.

Tijdens de run steeg globale swap vanaf 8816,44 MiB. De eerste bemonsterde
overschrijding bedroeg +1240,31 MiB tegenover de limiet van +1024 MiB. Na het
stoppen van de helper werd een hogere eindwaarde van 10641,75 MiB gemeten:
+1825,31 MiB tegenover de baseline. De hoogste drukwaarde was **2 (warning),
niet 4 (critical)**. Helper-RSS piekte op 2.870.558.720 bytes. Dit is geen volledige
Metal-/unified-memorymeting; globale swap kan niet uitsluitend aan dit model
worden toegeschreven. Het resultaat bewijst geen algemene ongeschiktheid van
16 GiB-Macs en zegt niets over een niet-geteste 128 GiB-Mac.

De warme helper reageerde niet binnen de vijf seconden wachttijd na SIGTERM
en is vervolgens uitsluitend op zijn eigen proces-ID met SIGKILL beëindigd.
Alle elf eigen child-processen (tien koude starts en één warme helper) zijn
achteraf als afwezig geverifieerd. Gebruikersprocessen zijn niet beëindigd.

| Waarneming, vanaf einde-invoercommit tenzij anders vermeld | Direct | Twee passes |
| --- | ---: | ---: |
| Voltooide transportturns | 80 | 80 |
| Geobserveerde mediaan eerste tekstdelta | 104 ms | 104 ms |
| Geobserveerde mediaan eerste ontvangen PCM | 232 ms | 1620 ms |
| Geobserveerd bereik eerste ontvangen PCM | 187–335 ms | 1445–2163 ms |

Dit zijn **geen p50/p95-claims**: iedere modusgroep heeft minder dan honderd
metingen; iedere combinatie van modus en richting heeft er veertig. De tekstdelta
is tentatief. Complete tekst na de externe guard kwam veel later: geobserveerde
medianen van 2571/2555 ms voor direct NL→EN/EN→NL en 1393/1536 ms voor twee
passes. De directe guard is in dit Python-harnas post-hoc, nadat audio al is
ontvangen. Deze waarden meten geen native captionweergave, microfoon/VAD,
hoorbare uitvoer of stop-tot-stilte. Koude procesreadiness had over tien starts
een geobserveerde mediaan van 627 ms en bereik 563–1120 ms; de OS-bestandscache
bleef behouden.

De betekenisfouten verdwenen niet tijdens de duurproef. Alle veertig voltooide
directe NL→EN-turns en alle veertig twee-pass-turns maakten “half vier” tot
“half past four”. Alle veertig directe EN→NL-turns veranderden de boekingsvraag
in “Bekijk”; alle veertig twee-pass-turns in “Vul”. De doeltaalguard accepteerde
de taal, maar heeft zonder brontranscript geen vergelijkbare invoertekst voor
deze betekeniscontrole. De letterlijke uitvoervarianten en aantallen staan in
het meetbewijs; dit is tekstinspectie, geen luisterbeoordeling of algemene
kwaliteitsmeting.

Een volledige duurtest onder dezelfde grenzen, voldoende waarnemingen per
percentielgroep, onderbrekingsproeven en menselijke tweetalige/stembeoordeling
blijven open. Er is geen automatische providerwissel, limietverruiming of
gekwalificeerde standaard ingesteld.

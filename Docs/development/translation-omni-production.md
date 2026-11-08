# LFM3-productieprompt: Q8 en Q4 op dezelfde opnames

Op 8 november 2026 zijn Q8_0 en Q4_K_M achtereenvolgens uitgevoerd met de
productie-instructies en de bijgewerkte taalcontrole uit appcommit
`68535271b2f0ab4baacd4e08981b213c21499141`. Beide runs gebruiken exact dezelfde
eerder gemaakte Nederlandse en Engelse synthetische WAV-bestanden als de
native cascadeproef. Er is geen nieuwe Apple-stem gegenereerd. Helper, modellen,
projector en de driver zijn gepind/gehasht; de
[volledige meetgegevens](translation-omni-production-evidence.json) bewaren
invoeridentiteit, werkelijke uitvoertekst, instructies, timings en beperkingen.

Beide runs voltooiden het technische transport, maar **beide modellen blijven
ongekwalificeerd**. De gekozen doeltaal klopte; de betekenis bevatte kritieke
fouten. De productieguard kan bij Omni zonder brontranscript alleen de
uitvoertaal controleren. Hij kan deze tijd- en intentiefouten niet betrouwbaar
tegen de gesproken invoer vergelijken.

| Model / route | Werkelijke NL→EN-tekst | Werkelijke EN→NL-tekst |
| --- | --- | --- |
| Q8 direct | “The appointment is at half past four, not at four o'clock.” | “Bekijk twee zitjes voor vrijdag, niet voor donderdag.” |
| Q8 twee passes | “The appointment is at half past four, not at four o'clock.” | “Vul alstublieft twee zitplaatsen voor vrijdag, niet voor donderdag.” |
| Q4 direct | “The appointment is at half past four, not at four o'clock.” | “Vergeten twee zitjes voor vrijdag, niet voor dinsdag.” |
| Q4 twee passes | “The appointment is at half four, not at four o'clock.” | “Vergeten twee zitplaatsen voor vrijdag, niet voor dinsdag.” |

De Nederlandse bron noemt **half vier**, dus 03:30/15:30. De Engelse bron vraagt
twee plaatsen te **reserveren** voor vrijdag en niet voor donderdag. Q8 verandert
de reserveringshandeling; Q4 verandert bovendien donderdag in dinsdag. “Half
four” is geen betrouwbare weergave van het Nederlandse half vier en betekent in
gangbaar Brits Engels half vijf in het Nederlands. Deze tekstinspectie is geen
beoordeling van de werkelijk uitgesproken audio door een luisteraar.

| Netwerkmeting, één waarneming per cel | Q8 NL→EN | Q8 EN→NL | Q4 NL→EN | Q4 EN→NL |
| --- | ---: | ---: | ---: | ---: |
| Direct: eerste tekstdelta na invoercommit | 345 ms | 357 ms | 299 ms | 334 ms |
| Direct: eerste ontvangen PCM na invoercommit | 446 ms | 458 ms | 368 ms | 405 ms |
| Twee passes: complete tekstrespons na commit | 541 ms | 755 ms | 407 ms | 474 ms |
| Twee passes: eerste PCM vanaf afzonderlijk `/tts`-verzoek | 91 ms | 89 ms | 86 ms | 89 ms |

De twee-pass-waarden mogen niet worden opgeteld tot gemeten totale audiolatency:
de tussenliggende socket- en guardafhandeling is hier niet afzonderlijk gemeten.
Geen van deze tijden meet microfoon/VAD, hoorbare uitvoer of native app-latency;
er zijn geen p50/p95-resultaten uit deze kleine matrix berekend.

Beide geheugenbaselines waren normaal en bleven niveau 1. Gemeten piek-RSS van
het eigen helperproces was 2.870.050.816 bytes voor Q8 en 2.123.612.160 bytes voor
Q4. De maximale globale swapgroei was in beide runs nul; dat is geen volledige
meting van het unified-memorygebruik. De 1024 MiB-grens bleef actief. Beide
helpers zijn gestopt, de sleutels zijn verwijderd en HTTP/WebSocket-authenticatie
en Origin-afwijzing zijn technisch bevestigd.

De kwaliteitsvolgorde blijft LFM3 direct → dezelfde Omni in twee passes →
expliciet gekozen alternatief. Deze resultaten rechtvaardigen geen
gekwalificeerde standaard of automatische fallback. De menselijke beoordeling,
werkelijk gesproken inhoud, 100 warme metingen, tien koude starts en duurproef
blijven afzonderlijke acceptatiepunten.

De eerste startpoging van de productie-duurproef (30 minuten, minimaal 200 warme
turns, tien koude starts, vijf onderbrekingen) is afgewezen door de
[geheugenvoorcontrole](translation-production-endurance-preflight.json).
Gedurende 60,061 seconden bleef de druk normaal en waren geen compilers zichtbaar,
maar systeemswap daalde van 9582,94 naar 9240,50 MiB. De range/nettoverandering van
342,44 MiB overschreed de vooraf vastgelegde stabiliteitsgrenzen van 128/64 MiB.
De grenzen zijn niet verruimd en er is tijdens die voorcontrole geen model geladen.
Dalende systeemswap betekent hier geen kritieke geheugendruk en bewijst geen
ongeschiktheid van 16 GiB-Macs; deze uitgangssituatie was nog onvoldoende stabiel.
Na gecontroleerd read-only wachten en een nieuwe geslaagde voorcontrole is de
[productie-duurproef](translation-production-endurance.md) wel gestart. Deze is
na 15 minuten en 22 seconden afgebroken op de vaste swapgrens; de mislukte
voorcontroles en de afgebroken run blijven afzonderlijk zichtbaar.

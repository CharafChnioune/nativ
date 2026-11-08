# Begrensde bescherming tegen vertaalfouten

`TranslationContentGuard` herschrijft geen tekst. Een waarschijnlijke fout geeft
een herstelbare `unsupportedOutput` zonder de bronzin of vertaling in de
foutmelding op te nemen. De cascade moet de herkende bron en het complete doel
controleren vóór gecommitteerde doeltekst en TTS. Dezelfde
`TranslationInterpreterPrompt` geeft LFM3 en de cascade vaste tolk-instructies,
waaronder algemene klokregels; er staan geen benchmarkzinnen in de prompt.

De bronvergelijking dekt momenteel alleen Nederlands–Engels:

- Herkenbare klokvormen: digitale tijden, Nederlandse halve uren/kwartieren,
  Engelse *half past*, *quarter to/past* en gangbare uitgesproken minuten.
  Nederlandse *half* verwijst naar het vorige uur. Zonder bekende dagperiode
  vergelijkt de controle op een 12-uursklok; expliciete digitale AM/PM kan met
  herkenbare 24-uursnotatie worden vergeleken.
- Expliciete getallen, locale decimalen/groepering en kleine telwoorden.
  Alleenstaande *one/een/1* blijven buiten de vergelijking vanwege hun functie
  als voornaamwoord of lidwoord. Breuken, uitgesproken decimalen, grote
  schaalwoorden en alternatieve datum-/versienotaties worden niet als volledig
  begrepen behandeld. Getallen worden als verzameling met multipliciteit
  vergeleken; verwisseling van getallen tussen personen wordt hiermee niet bewezen.
- Expliciete negatie en enkele vaste negatieve woorden. Bekende idiomen worden
  overgeslagen om geldige parafrases niet zomaar te weigeren. Dit is geen analyse
  van logische reikwijdte: dubbele negatie en onbekende parafrases kunnen buiten
  de dekking vallen of een herhaalverzoek veroorzaken.

Taalherkenning is injecteerbaar. Standaard levert `NLLanguageRecognizer` een lokale
hint. Alleen langere uitingen met ten minste vijf woorden, 24 letters en
confidence ≥0,98 worden op een andere doeltaal geweigerd. Korte namen, losse
woorden en onzekere uitingen worden niet op die basis afgekeurd. Confidence
is geen gemeten vertaalkwaliteit en taalherkenning kan zich vergissen.

Omni levert in deze integratie geen brontranscript. Twee passes controleren de
doeltaal vóór `/tts`; tekst blijft daarvoor tentatief. Direct Omni kan audio al
hebben uitgegeven voordat een taalprobleem zichtbaar wordt. Geen van beide routes
krijgt hierdoor een garantie voor getallen, ontkenning of betekenisbehoud. Een
geslaagde heuristische controle kwalificeert geen model of talenpaar; de echte
opnames, stembeoordeling en duur-/latencymetingen blijven vereist.

Deterministische regressies staan in `TranslationContentGuardTests` en
`LFM3BackendTests`, inclusief tijdverschuiving, getal-/negatieverandering,
conservatieve uitzonderingen, privacy en verkeerde doeltaal vóór two-pass TTS.
Dit is geen nieuwe modelbenchmark.

# Begrensde controle op verkeerde uitvoertaal

De uitvoercontrole blokkeert een langere zin wanneer `NLLanguageRecognizer`
een andere taal aanwijst dan de gekozen doeltaal. Voor verwarring tussen
Nederlands en Engels geldt een grens van `0.90`; andere taalcombinaties houden
`0.98`. De grens van minimaal vijf woorden én 24 letters blijft gelijk.
Taalsuffixen zoals `en-US` en `nl-NL` worden voor deze vergelijking genormaliseerd.
Een passende doeltaal wordt nooit vanwege deze score afgewezen.

De wijziging is gebaseerd op een lichte OS-classifierproef van 8 november 2026,
zonder modelinference, microfoon of spraakuitvoer. De zestig oorspronkelijke
conceptreferenties uit `fixture-manifest.json` zijn vergeleken met de bijbehorende
zestig bronzinnen die bewust als verkeerde doeltaal werden aangeboden.
Het [meetbewijs](translation-language-guard-evidence.json) bevat de fixturehash,
OS-versie, scores, tekstlengtes en individuele beslissingen per kandidaatbeleid.

| Grens | Foutief afgewezen conceptreferenties | Herkende verkeerde doeltaal | Gemiste langere verkeerde doeltaal |
| --- | ---: | ---: | ---: |
| `0.98` | 0 / 60 | 50 / 60 | 4 / 54 |
| `0.95` | 0 / 60 | 53 / 60 | 1 / 54 |
| `0.90` | 0 / 60 | 54 / 60 | 0 / 54 |

Zes bronzinnen zijn te kort voor de controle en blijven bij alle grenzen bewust
ongemoeid. Ook zes correcte conceptreferenties vallen buiten die lengtegrens.
De concrete Engelse zin “Please bring the original document to our office
tomorrow morning.” kreeg score `0.9768291115760803` en werd bij Nederlandse
uitvoer door de oude grens doorgelaten. De nieuwe NL/EN-grens blokkeert dit geval.
Een extra top-2-marge van `0.2` of `0.5` veranderde in deze steekproef geen uitkomst;
er is daarom geen extra detectie-interface toegevoegd.

Deze OS-scores zijn heuristische signalen, geen gekalibreerde kansen. De
conceptreferenties zijn nog niet door tweetalige beoordelaars goedgekeurd.
Deze proef bewijst geen algemene vertaalcorrectheid, spraakkwaliteit,
automatische-richtingkwalificatie of werking voor andere talen. Korte,
gemengde of anders geformuleerde tekst kan nog steeds verkeerd door de controle
komen. Getallen-, tijd- en negatiecontroles blijven afzonderlijke beperkte
heuristieken; er wordt geen tekst herschreven en geen provider vervangen.

`TranslationContentGuardTests` legt de beslisgrenzen vast met geïnjecteerde
taalscores: NL/EN-afwijzing vanaf `0.90`, onthouding bij `0.89` en korte tekst,
acceptatie van passende taal en behoud van `0.98` bij andere combinaties.
De actuele OS-score zelf is bewust geen vaste unit-testassertie, omdat die met
een OS-versie kan veranderen. Native uitvoering van deze nieuwe tests wordt
in het gezamenlijke validatierapport geregistreerd.

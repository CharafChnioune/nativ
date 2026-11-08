# Onafhankelijke lokale modelkeuze

Translate behoudt **LFM3-Omni direct → dezelfde Omni in twee passes → expliciet gekozen alternatief** als voorkeursvolgorde. In de lokale cascade zijn herkenning, tekstvertaling en spraakuitvoer afzonderlijke keuzes uit de bestaande geïnstalleerde modellenlijst. Geen fout activeert automatisch Apple, een cloudprovider of een ander model.

`TranslationStageCatalog` maakt onderscheid tussen een beschikbare taakloader, gedocumenteerde talen en kwalificatie. Geen nieuw catalogusprofiel is daarmee praktisch gekwalificeerd. De taalparen van een generatief taalmodel blijven expliciet experimenteel totdat dat exacte model is gemeten. ASR- en TTS-taalgrenzen worden apart gecontroleerd vóór invoer wordt verwerkt.

| Taak | Adapter | Grenzen |
| --- | --- | --- |
| ASR | Whisper-varianten | Vocabulaire 51864: Engels; 51865: 99 talen zonder Kantonees; 51866: 100 talen inclusief Kantonees. De catalogus volgt de native/Hugging Face-dimensies van de loader. Ontbrekende of onbekende metadata maken een checkpoint niet selecteerbaar. Alleen `transcribe`, nooit Whisper's Engelse `translate` als algemene vertaler. |
| ASR | Qwen3-ASR | De 30 gedocumenteerde talen worden doorsneden met `support_languages` in de gekozen configuratie. De aanvraag gebruikt de taalnaam die dit model verwacht. |
| ASR | Parakeet TDT 0.6B v2/v3 | v2 Engels; v3 25 Europese talen. De modelnaam moet het expliciete profiel identificeren. Geen geforceerde taalhint: de adapter transcribeert de door Parakeet herkende taal. |
| Vertaling | Generatieve lokale MLX-modellen, bijvoorbeeld Gemma, Qwen of LFM | Alleen modellen uit Nativ's generatieve modelselector, geen embeddings/rerankers/drafters. Gebruik een instructiemodel. De gekozen taalcombinatie is experimenteel; een taakloader is geen kwaliteitsbewijs. |
| TTS | LFM3-Omni | Voorkeur voor lokale spraak; dezelfde gepinde helper en werkelijk ontvangen streamingformaten. Eigen taalgrenzen blijven gelden. |
| TTS | Chatterbox | Engels of de 23 gedocumenteerde meertalige talen volgens de concrete variant. Lokale toegestane stemreferentie vereist. De HTTP-adapter levert complete frases. |
| TTS | Qwen3-TTS CustomVoice | Alleen stemmen uit de lokale `spk_id`-tabel; expliciete stemkeuze. De taal moet in de tien gedocumenteerde talen én de lokale `codec_language_id` voorkomen. Nederlands wordt geweigerd. |
| TTS | Qwen3-TTS Base | Dezelfde taalgrens; vereist een toegestane lokale referentie met de correcte tekst van die opname. VoiceDesign wordt niet stilzwijgend als Base of CustomVoice behandeld. |
| TTS | Kokoro | Taalgrenzen en lokale stemmen zijn zichtbaar, maar momenteel **niet beschikbaar**: de gepinde distributie bevat geen voorbereide Misaki/eSpeak-data. Alleen modelgewichten installeren is onvoldoende. Nederlands is ook geen ondersteunde Kokoro-taal. |
| TTS | Apple | Uitsluitend expliciete extra keuze met een geïnstalleerde stem voor de doeltaal. |

Qwen3-TTS kan in andere interfaces streaming hebben. Deze Nativ-adapter vraagt bewust `stream=false` en decodeert de volledige WAV; hij heeft daarom geen streaminglabel. Playbackchunks uit een complete WAV veranderen dat niet. Stemnatuurlijkheid, emotionele intentie en verstaanbaarheid zijn niet automatisch gekwalificeerd.

## Experimentele richting en begrensde replay

Vaste richting blijft de standaard. Alleen de lokale cascade kan een **afzonderlijk expliciet geaccepteerde, ongekwalificeerde automatische richting** aanbieden. Vooraf moeten beide talen door ASR, het taalmodel en, bij gesproken uitvoer, TTS worden ondersteund. ASR ontvangt dan geen taalhint. Daarna bepaalt een injecteerbare teksttaaldetector of de werkelijk herkende tekst voldoende aanwijzingen bevat voor één van de twee talen; de andere taal wordt het doel. De detector gebruikt lokale NaturalLanguage-tekstclassificatie, geen Apple TTS. Zijn score is een heuristische taalhint, geen gemeten kans op correcte vertaling.

Korte invoer, lage of verdeelde scores, een derde taal en aangetroffen gemengde taal leiden tot onthouding: de echte brontranscriptie blijft zichtbaar, vertaling/TTS starten niet en de gebruiker krijgt een herstelbare richtingsfout. De conservatieve heuristiek garandeert niet dat iedere taalwisseling of elk mengsel wordt gevonden. Automatische richting blijft daarom ongekwalificeerd totdat afzonderlijke originele tweetalige opnamen zijn beoordeeld.

**Retranslate** bewaart maximaal één invoersegment van maximaal twaalf seconden gedurende maximaal dertig seconden in geheugen. Dat ene slot is óf de laatste voltooide opname óf de volledige invoer van een herstelbare fout. Retry en gecorrigeerde replay gebruiken hetzelfde slot. Een expliciete replay maakt de generatie onmiddellijk ongeldig, bouwt de oude backendcontext af en bereidt dezelfde provider voor met de gekozen vaste richting. Het PCM krijgt een nieuwe turn-/generation-ID; de transcriptgeschiedenis bezit geen PCM. Stop, wisselen van sessie-instellingen en de vervaltimer wissen het slot. Een niet-ondersteunde gecorrigeerde richting veroorzaakt geen model- of stemvervanging.

De cascade bewaart geen gesprekcontext tussen afzonderlijke HTTP-frases (`retainsConversationContext=false`). De sessiekern voert daarvoor geen kunstmatige contextrollover na elke turn uit. Resident-modus kan modellen daardoor tussen turns warm houden; Stop/interruptie/fouten blijven de eigen resourcegeneratie daadwerkelijk ongeldig maken.

## Assets en offline werking

Openen van Translate start geen download. De expliciete actie **Prepare speech assets** bereidt Chatterbox-onderdelen voor in de eigen `nativ-translation/cascade`-map op het ingestelde cachevolume. De geselecteerde Hugging Face-snapshot en `refs/main` blijven intact. Complete gepinde bestanden uit de normale cache kunnen na hashcontrole worden hergebruikt. Downloadruimte wordt via dezelfde reserveringsservice als andere Nativ-downloads beheerd; tijdelijke bestanden worden eerst geverifieerd en daarna atomair geïnstalleerd.

De Chatterbox-loader krijgt `nativ_speech_tokenizer_path` met het geverifieerde pad. De requestgebonden Python-policy bindt uitsluitend `mlx-community/S3TokenizerV2` aan dat pad en forceert voor andere Hub-assetaanvragen `local_files_only=true`. Oudere runtimes zonder `pinned_speech_assets_policy=1` worden geweigerd voordat spraaktekst wordt verzonden. Deze policy wijzigt geen modelverzoeken van de gewone chatserver.

| Artifact | Revisie | Bestand | Bytes | SHA-256 |
| --- | --- | --- | ---: | --- |
| S3TokenizerV2 | `e0c9886f0e1c35ae85b1f27277416fb19fc72bec` | `model.safetensors` | 494868984 | `928726bc1f206a613d36b8f49e297eae9c5593a21bf9b92ddfe2c23f85eb92cc` |
| S3TokenizerV2 | dezelfde | `config.json` | 126 | `8591fcc0eaae8c2bbfc69cf9d439933ecdf2d58cb9be63d00ce88736c4f2aa9d` |
| S3TokenizerV2 | dezelfde | `README.md` | 459 | `7114249e13d3487e1b3d7f5f91fefdce746679342dca7afc8e52b1617b66bea5` |
| Chatterbox meertalige karakterkaart | `03565773edd72e949572557597af8063bb49a18a` | `Cangjie5_TC.json` | 1920163 | `7073fd9de919443ae88e0bd2449917a65fe54898a4413ed1edcc4b67f28bce8c` |

Chatterbox's modelkaart vermeldt MIT. De S3TokenizerV2-conversiekaart verwijst naar CosyVoice2 als bron maar vermeldt zelf geen licentieveld; die aanvullende licentieherkomst blijft een distributiereviewpunt. Deze wijziging bundelt de gewichten niet en maakt daarvan geen afgeronde releasekwalificatie.

Qwen3-TTS moet een volledige geselecteerde snapshot hebben: teksttokenizer, `speech_tokenizer/config.json` en de safetensors van die spraaktokenizer. De voorbereiding verifieert aanwezigheid; ze claimt geen gepinde releasekwalificatie voor willekeurige door de gebruiker gekozen modellen. Referentie-opnamen zijn expliciete lokale bestanden van maximaal 20 MB; ze worden niet automatisch gedownload of geüpload.

## Bronnen en bewijsgrens

De families zijn vergeleken met de meegeleverde MLX-Audio 0.6.4-implementaties en primaire modelinformatie op 8 november 2026: [Qwen3-ASR](https://huggingface.co/Qwen/Qwen3-ASR-0.6B), [Parakeet v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), [Qwen3-TTS CustomVoice-configuratie](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice/blob/main/config.json), [Chatterbox](https://huggingface.co/mlx-community/chatterbox-multilingual-v3/tree/03565773edd72e949572557597af8063bb49a18a) en [S3TokenizerV2](https://huggingface.co/mlx-community/S3TokenizerV2/tree/e0c9886f0e1c35ae85b1f27277416fb19fc72bec). Loaderondersteuning en deze documenten vervangen geen gemeten inferentie, vertaalbeoordeling of stemacceptatie. De nieuwe Qwen/Parakeet/TTS-combinaties zijn in deze wijziging niet met hun gewichten doorgemeten.

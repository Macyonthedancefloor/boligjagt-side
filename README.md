# Boligjagt

Henter ledige lejligheder fra BoligPortal og Homes and Housing hvert kvarter
og bygger en side, hvor hver bolig har en færdig henvendelse klar til at
kopiere.

## Privatliv

Repoet og den offentlige side indeholder **ingen personlige oplysninger**.

Navn, kontaktinfo og teksten om ansøgeren gemmes udelukkende i browserens
`localStorage` på den enkelte enhed. De sendes ingen steder hen, indgår ikke
i siden, og er ikke synlige for andre. Selve henvendelsen sættes sammen i
browseren, når man trykker kopiér.

**Skriv derfor aldrig navn, telefonnummer, mailadresse eller anden personlig
tekst ind i `hent.py` eller `skabelon.html`.** De filer er offentlige.

## Filer

| Fil | Rolle |
|---|---|
| `hent.py` | Henter og fortolker annoncer, skriver `index.html` |
| `skabelon.html` | Sidens udseende og logik. Data indsættes ved `/*DATA*/` |
| `index.html` | Den byggede side. Genereres, redigér den ikke i hånden |
| `state.json` | Hvilke annoncer der er set før, så "Ny" betyder noget |

## Sådan virker det

BoligPortal leveres som server-renderet HTML, der fortolkes med regex.
Alt fra og med overskriften "Lignende annoncer" klippes fra, da det er
anbefalinger fra andre områder end søgningen.

Homes and Housing har et JSON-api på `/Umbraco/Api/Ajax/getAppartments`,
der svarer på formular-kodede felter og leverer to boliger ad gangen.
Deres api oplyser ikke, hvornår en bolig blev lagt op, så de vises med
"set for X siden" i stedet for en opdigtet alder.

Der bruges ingen sprogmodel undervejs. Kørslerne er derfor forudsigelige
og giver samme resultat hver gang.

## Kørsel lokalt

```bash
python3 hent.py
python3 -m http.server 8000
```

Åbn derefter <http://localhost:8000>.

#!/usr/bin/env python3
"""
Henter ledige lejligheder fra BoligPortal og Homes and Housing og skriver
dem til index.html.

Indeholder BEVIDST ingen personlige oplysninger. Siden er offentlig, saa
selve ansoegningsbeskeden bliver sat sammen i browseren ud fra det, brugeren
selv har gemt lokalt. Skriv aldrig navn, telefon eller mail ind i denne fil.

Koerer uden AI: ren parsing, saa resultatet er det samme hver gang.
"""

import html
import json
import os
import re
import sys
import urllib.request
from datetime import datetime, timedelta, timezone

# ---------------------------------------------------------------- opsaetning

SOEGE_URL = (
    "https://www.boligportal.dk/lejligheder/k%C3%B8benhavn/2-v%C3%A6relser/"
    "?max_monthly_rent=15000"
)

# Homes and Housing er et udlejningsbureau i den dyrere ende. De har et rent
# JSON-api, saa vi spoerger det direkte i stedet for at laese HTML.
# Bemaerk: mange af deres billigste boliger er forbeholdt expats. Vi sorterer
# dem ikke fra, men markerer dem tydeligt, saa valget er brugerens eget.
HH_API = "https://homesandhousing.dk/Umbraco/Api/Ajax/getAppartments"
HH_MAX_LEJE = 15000

# Alt efter denne overskrift er BoligPortals egne anbefalinger fra andre
# omraader, fx Hoersholm og Birkeroed. De skal IKKE med.
STOP_OVERSKRIFT = "Lignende annoncer"

HER = os.path.dirname(os.path.abspath(__file__))
STATE_FIL = os.path.join(HER, "state.json")
SIDE_FIL = os.path.join(HER, "index.html")

DK_TZ = timezone(timedelta(hours=2))  # dansk sommertid

MAANEDER = {
    "januar": 1, "februar": 2, "marts": 3, "april": 4, "maj": 5, "juni": 6,
    "juli": 7, "august": 8, "september": 9, "oktober": 10,
    "november": 11, "december": 12,
}

# ------------------------------------------------------------------ hentning

def hent_side(url):
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                          "AppleWebKit/537.36 (KHTML, like Gecko) "
                          "Chrome/124.0 Safari/537.36",
            "Accept-Language": "da-DK,da;q=0.9",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as svar:
        if svar.status != 200:
            raise RuntimeError(f"BoligPortal svarede {svar.status}")
        return svar.read().decode("utf-8", errors="replace")


def rens(fragment):
    """Fjerner HTML-kommentarer og tags, og folder mellemrum sammen."""
    uden = re.sub(r"<!--.*?-->", "", fragment, flags=re.S)
    uden = re.sub(r"<[^>]+>", "", uden)
    return re.sub(r"\s+", " ", html.unescape(uden)).strip()


def parse_annoncer(side):
    # Klip alt væk fra og med anbefalingerne.
    graense = side.find(STOP_OVERSKRIFT)
    if graense != -1:
        side = side[:graense]

    fundne = []
    moenster = r'<a class="group[^"]*" href="(/lejligheder/[^"]*?id-(\d+))"(.*?)</a>'
    for sti, annonce_id, krop in re.findall(moenster, side, re.S):
        def find(pat):
            traef = re.search(pat, krop, re.S)
            return rens(traef.group(1)) if traef else None

        titel = find(r"<h3[^>]*>(.*?)</h3>")
        sted = find(r'<p class="text-muted[^"]*"[^>]*>(.*?)</p>')
        if not (titel and sted):
            continue

        husleje = find(r'<span class="font-bold">(.*?)</span>')
        alder_tekst = find(r'<span class="text-muted text-xs">(.*?)</span>')

        # "Fri kontakt" betyder at man maa skrive til udlejeren uden et
        # betalt medlemskab hos BoligPortal. Uden det kan man se annoncen,
        # men ikke sende noget.
        fri_kontakt = "Fri kontakt" in krop

        # Foerste billede paa kortet. Kortet har typisk fem.
        billede = re.search(r'<img[^>]*\bsrc="([^"]+)"', krop)
        billede = html.unescape(billede.group(1)) if billede else None

        stoerrelse = re.search(r"(\d+)\s*m²", titel)
        dele = [d.strip() for d in sted.split(",")]
        omraade = dele[0]
        vej = dele[-1] if len(dele) > 1 else ""

        fundne.append({
            "id": annonce_id,
            "sti": sti,
            "url": "https://www.boligportal.dk" + sti,
            "vej": vej,
            "omraade": omraade,
            "husleje": husleje,
            "stoerrelse": stoerrelse.group(1) + " m²" if stoerrelse else None,
            "alder_tekst": alder_tekst,
            "billede": billede,
            "fri_kontakt": fri_kontakt,
        })
    return fundne


# ------------------------------------------------- Homes and Housing (api)

def _tal(tekst):
    """'12.500' -> 12500. Returnerer 0 hvis der ikke er tal."""
    return int(re.sub(r"\D", "", tekst or "") or 0)


def hent_homesandhousing():
    """
    Henter boliger fra Homes and Housing under HH_MAX_LEJE.
    Api'et leverer to ad gangen, saa vi bladrer til det loeber toert.
    Fejler den, returnerer vi tom liste: BoligPortal skal stadig virke.
    """
    import urllib.parse

    fundne, sete_id = [], set()
    for side in range(12):
        felter = urllib.parse.urlencode({
            "page": side, "language": "da",
            "kvmMin": 0, "kvmMax": 500,
            "priceMin": 0, "priceMax": 100000,
            "furnitured": "false",
        }).encode()
        req = urllib.request.Request(
            HH_API, data=felter,
            headers={
                "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
                "X-Requested-With": "XMLHttpRequest",
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                              "AppleWebKit/537.36 (KHTML, like Gecko) "
                              "Chrome/124.0 Safari/537.36",
            },
        )
        try:
            svar = json.load(urllib.request.urlopen(req, timeout=25))
        except Exception as fejl:
            print(f"advarsel: Homes and Housing side {side} fejlede: {fejl}",
                  file=sys.stderr)
            break
        if isinstance(svar, str):
            svar = json.loads(svar)
        if not svar:
            break

        nyt_paa_siden = False
        for bolig in svar:
            nid = str(bolig.get("nodeId") or bolig.get("appartmentUmbracoId") or "")
            if not nid or nid in sete_id:
                continue
            sete_id.add(nid)
            nyt_paa_siden = True

            leje = _tal(bolig.get("monthlyRent"))
            if not leje or leje > HH_MAX_LEJE:
                continue

            beskrivelse = (bolig.get("beskrivelseDA") or "") + (bolig.get("beskrivelseEN") or "")
            fundne.append({
                "id": "hh-" + nid,
                "kilde": "Homes and Housing",
                "url": "https://homesandhousing.dk" + (bolig.get("link") or ""),
                "vej": (bolig.get("address") or "").strip(),
                "omraade": (bolig.get("city") or "").strip(),
                "husleje": f"{bolig.get('monthlyRent')} kr.",
                "stoerrelse": (bolig.get("squarefeet") or "") + " m²"
                              if bolig.get("squarefeet") else None,
                "fri_kontakt": True,   # bureauet har ingen betalingsmur
                "aconto": (str(bolig.get("aCForbrug")) + " kr.")
                          if bolig.get("aCForbrug") else None,
                "billede": ("https://homesandhousing.dk"
                            + (bolig.get("galleri") or "").split(";")[0])
                           if (bolig.get("galleri") or "").strip() else None,
                "alder_tekst": None,          # api'et oplyser ikke hvornaar den blev lagt op
                "kun_expats": bool(re.search(r"expat", beskrivelse, re.I)),
                "ledig_fra": bolig.get("readyFromDate"),
                "indflytningspris": bolig.get("indflytningspris"),
            })
        if not nyt_paa_siden:
            break
    return fundne




# ------------------------------------------------- detaljer pr. annonce

def _tal_efter(tekst, maerke):
    """Finder beloebet lige efter et maerkat, fx 'Aconto 700 kr.'"""
    m = re.search(re.escape(maerke) + r"\s*([\d.]+(?:,\d+)?)\s*kr", tekst, re.I)
    return (m.group(1) + " kr.") if m else None


def hent_detaljer(url):
    """
    Aconto og depositum staar kun paa annoncens egen side, ikke i soegningen.
    Siden er stor, saa den hentes kun een gang pr. annonce og gemmes derefter
    i state.json. Fejler den, faar vi bare ingen detaljer for den bolig.
    """
    try:
        raa = hent_side(url)
    except Exception:
        return {}
    uden = re.sub(r"<(script|style)[^>]*>.*?</\1>", " ", raa, flags=re.S | re.I)
    uden = re.sub(r"<[^>]+>", " ", uden)
    tekst = re.sub(r"\s+", " ", html.unescape(uden))
    return {
        "aconto": _tal_efter(tekst, "Aconto"),
        "depositum": _tal_efter(tekst, "Depositum"),
        "forudbetalt": _tal_efter(tekst, "Forudbetalt husleje"),
        "indflytning": _tal_efter(tekst, "Indflytningspris"),
    }

# --------------------------------------------------------------------- alder

def gaet_oprettet(alder_tekst, nu):
    """
    Oversaetter BoligPortals alderstekst til et omtrentligt tidspunkt.
    Vi gemmer det een gang, saa alderen forbliver rigtig ved senere koersler.
    """
    if not alder_tekst:
        return nu
    t = alder_tekst.lower().strip()

    if "lige nu" in t or "minut" in t:
        tal = re.search(r"(\d+)", t)
        return nu - timedelta(minutes=int(tal.group(1)) if tal else 1)
    if "time" in t:
        tal = re.search(r"(\d+)", t)
        return nu - timedelta(hours=int(tal.group(1)) if tal else 1)
    if "i går" in t:
        return nu - timedelta(days=1)
    if "dag" in t:
        tal = re.search(r"(\d+)", t)
        return nu - timedelta(days=int(tal.group(1)) if tal else 1)

    # Formen "12. august"
    dato = re.match(r"(\d+)\.\s*([a-zæøå]+)", t)
    if dato:
        dag, maaned = int(dato.group(1)), MAANEDER.get(dato.group(2))
        if maaned:
            aar = nu.year if maaned <= nu.month else nu.year - 1
            try:
                return datetime(aar, maaned, dag, 12, 0, tzinfo=DK_TZ)
            except ValueError:
                pass
    return nu


def alder_dansk(oprettet, nu):
    d = nu - oprettet
    minutter = int(d.total_seconds() // 60)
    if minutter < 2:
        return "lige nu"
    if minutter < 60:
        return f"{minutter} minutter siden"
    timer = minutter // 60
    if timer < 24:
        return f"{timer} time siden" if timer == 1 else f"{timer} timer siden"
    dage = timer // 24
    if dage == 1:
        return "i går"
    if dage < 31:
        return f"{dage} dage siden"
    return oprettet.strftime("%-d/%-m")


# ------------------------------------------------------------------- tilstand

def laes_state():
    if not os.path.exists(STATE_FIL):
        return {}
    try:
        with open(STATE_FIL, encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (json.JSONDecodeError, OSError):
        return {}


def skriv_state(state):
    with open(STATE_FIL, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, indent=1, sort_keys=True)


# ------------------------------------------------------------------- udskrift

def byg_side(annoncer, nye_ider, nu):
    """
    Skriver index.html. Siden indeholder KUN oplysninger om lejligheder.
    Beskeden til udlejer bliver sat sammen i browseren ud fra det, brugeren
    har gemt lokalt paa sin egen enhed.
    """
    kort = ["jan.", "feb.", "mar.", "apr.", "maj", "jun.",
            "jul.", "aug.", "sep.", "okt.", "nov.", "dec."][nu.month - 1]
    opdateret = f"{nu.day}. {kort} {nu.year} kl. {nu:%H.%M}"

    data = []
    for a in annoncer:
        data.append({
            "id": a["id"],
            "billede": a.get("billede") or "",
            "vej": a.get("vej") or a.get("omraade") or "",
            "omraade": a.get("omraade") or "",
            "husleje": a.get("husleje") or "",
            "stoerrelse": a.get("stoerrelse") or "",
            "alder": a.get("alder_vist") or "",
            "url": a.get("url") or "",
            "kilde": a.get("kilde") or "BoligPortal",
            "ny": a["id"] in nye_ider,
            "expat": bool(a.get("kun_expats")),
            "advarsel": bool(a.get("advarsel")),
            "fri": bool(a.get("fri_kontakt")),
            "aconto": a.get("aconto") or "",
            "depositum": a.get("depositum") or "",
            "forudbetalt": a.get("forudbetalt") or "",
            "indflytning": a.get("indflytning") or a.get("indflytningspris") or "",
            "lejetal": _tal(a.get("husleje")),
            "acontotal": _tal(a.get("aconto")),
            "ledig": a.get("ledig_fra") or "",
        })

    nyttedata = json.dumps(
        {"opdateret": opdateret, "antal": len(data),
         "nye": len(nye_ider), "boliger": data},
        ensure_ascii=False,
    )

    with open(os.path.join(HER, "skabelon.html"), encoding="utf-8") as f:
        skabelon = f.read()

    with open(SIDE_FIL, "w", encoding="utf-8") as f:
        f.write(skabelon.replace("/*DATA*/null/*DATA*/", nyttedata))


# ----------------------------------------------------------------------- main

def main():
    nu = datetime.now(DK_TZ)

    try:
        side = hent_side(SOEGE_URL)
    except Exception as fejl:
        print(f"FEJL: kunne ikke hente BoligPortal: {fejl}", file=sys.stderr)
        return 1

    annoncer = parse_annoncer(side)
    if not annoncer:
        print("FEJL: ingen annoncer parset. Har BoligPortal aendret HTML?", file=sys.stderr)
        return 1
    for a in annoncer:
        a.setdefault("kilde", "BoligPortal")

    # Homes and Housing er en ekstra kilde. Fejler den, koerer resten alligevel.
    hh = hent_homesandhousing()
    print(f"BoligPortal: {len(annoncer)} | Homes and Housing: {len(hh)}")
    annoncer += hh

    state = laes_state()
    foerste_koersel = not state
    nye_ider = []

    for a in annoncer:
        gemt = state.get(a["id"])
        if gemt is None:
            oprettet = gaet_oprettet(a.get("alder_tekst"), nu)
            state[a["id"]] = {
                "oprettet": oprettet.isoformat(),
                "foerst_set": nu.isoformat(),
                "vej": a["vej"],
            }
            if not foerste_koersel:
                nye_ider.append(a["id"])
        else:
            try:
                oprettet = datetime.fromisoformat(gemt["oprettet"])
            except (KeyError, ValueError):
                oprettet = nu

        # Detaljer hentes een gang pr. annonce og genbruges derefter.
        # Homes and Housing leverer dem allerede i deres api.
        if a.get("kilde") == "BoligPortal":
            gemte = (gemt or {}).get("detaljer") if gemt else None
            if gemte is None:
                gemte = hent_detaljer(a["url"])
                state[a["id"]]["detaljer"] = gemte
            else:
                state[a["id"]]["detaljer"] = gemte
            a.update({k: v for k, v in gemte.items() if v})

        a["oprettet"] = oprettet
        # Kilder uden opslagsdato (Homes and Housing) maa noejes med hvornaar
        # VI saa boligen. Det skriver vi aabent, saa en gammel bolig ikke
        # kommer til at se splinterny ud.
        if a.get("alder_tekst"):
            a["alder_vist"] = alder_dansk(oprettet, nu)
        else:
            a["alder_vist"] = "set " + alder_dansk(oprettet, nu)

        # Mistaenkeligt lav husleje: over 50 m2 til under 6.000 kr.
        pris = re.sub(r"[^\d]", "", (a.get("husleje") or "").split(",")[0])
        kvm = re.sub(r"[^\d]", "", a.get("stoerrelse") or "")
        a["advarsel"] = bool(pris and kvm and int(pris) < 6000 and int(kvm) > 50)

    annoncer.sort(key=lambda a: a["oprettet"], reverse=True)

    byg_side(annoncer, nye_ider, nu)
    skriv_state(state)

    if foerste_koersel:
        print(f"Foerste koersel: {len(annoncer)} annoncer gemt som udgangspunkt.")
    else:
        print(f"{len(annoncer)} annoncer, {len(nye_ider)} nye: "
              f"{', '.join(nye_ider) if nye_ider else 'ingen'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

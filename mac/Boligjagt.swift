// Boligjagt: en lille menulinje-app til macOS.
//
// Den henter den samme side som telefonen viser, holder styr paa hvilke
// boliger den har set foer, og giver en notifikation naar der kommer en ny.
// Al logikken om at hente og fortolke annoncer ligger i hent.py paa GitHub,
// saa appen behoever kun at laese resultatet.

import AppKit
import UserNotifications

let SIDE_URL = URL(string: "https://macyonthedancefloor.github.io/boligjagt-side/")!
let TJEK_INTERVAL: TimeInterval = 15 * 60
let HUSKE_NOEGLE = "sete-boliger"

// MARK: - Data fra siden

struct Bolig: Codable {
    let id: String
    let vej: String
    let omraade: String
    let husleje: String
    let stoerrelse: String
    let alder: String
    let url: String
    let kilde: String
    let expat: Bool
    let advarsel: Bool

    var overskrift: String {
        let sted = vej.isEmpty ? omraade : vej
        return sted.isEmpty ? "Ukendt adresse" : sted
    }

    var linje: String {
        var dele = [overskrift]
        if !omraade.isEmpty && omraade != overskrift { dele.append(omraade) }
        var hale: [String] = []
        if !husleje.isEmpty { hale.append(husleje) }
        if !stoerrelse.isEmpty { hale.append(stoerrelse) }
        if !alder.isEmpty { hale.append(alder) }
        let venstre = dele.joined(separator: ", ")
        return hale.isEmpty ? venstre : "\(venstre)  ·  \(hale.joined(separator: " · "))"
    }
}

struct Sidedata: Codable {
    let opdateret: String
    let antal: Int
    let boliger: [Bolig]
}

// MARK: - App

class Styring: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    var punkt: NSStatusItem!
    var ur: Timer?
    var boliger: [Bolig] = []
    var sidstOpdateret = "henter…"
    var sidsteFejl: String?
    var maaSendeBesked = false

    func applicationDidFinishLaunching(_ note: Notification) {
        punkt = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let knap = punkt.button {
            knap.image = ordmaerke()
            knap.imagePosition = .imageLeading
        }
        punkt.menu = NSMenu()
        tegnMenu()

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { givet, _ in
            self.maaSendeBesked = givet
        }

        hent()
        ur = Timer.scheduledTimer(withTimeInterval: TJEK_INTERVAL, repeats: true) { _ in
            self.hent()
        }
    }

    /// Ordmaerket til menulinjen. Tegnes som skabelonbillede, saa macOS selv
    /// farver det sort eller hvidt efter lyst og moerkt tema.
    func ordmaerke() -> NSImage {
        let ord = "BJAGT" as NSString
        let skrift = NSFont.systemFont(ofSize: 11, weight: .heavy)
        let egenskaber: [NSAttributedString.Key: Any] = [
            .font: skrift,
            .foregroundColor: NSColor.black,
            .kern: 0.4,
        ]
        let str = ord.size(withAttributes: egenskaber)
        let hoejde: CGFloat = 16
        let billede = NSImage(size: NSSize(width: ceil(str.width) + 2, height: hoejde))
        billede.lockFocus()
        ord.draw(at: NSPoint(x: 1, y: (hoejde - str.height) / 2),
                 withAttributes: egenskaber)
        billede.unlockFocus()
        billede.isTemplate = true
        return billede
    }

    // MARK: hentning

    func hent() {
        var forespoergsel = URLRequest(url: SIDE_URL)
        // GitHub Pages cacher gerne. Vi vil have det nyeste.
        forespoergsel.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        forespoergsel.timeoutInterval = 25

        URLSession.shared.dataTask(with: forespoergsel) { data, svar, fejl in
            if let fejl = fejl {
                DispatchQueue.main.async {
                    self.sidsteFejl = fejl.localizedDescription
                    self.tegnMenu()
                }
                return
            }
            guard let data = data, let html = String(data: data, encoding: .utf8) else {
                DispatchQueue.main.async {
                    self.sidsteFejl = "Kunne ikke laese siden."
                    self.tegnMenu()
                }
                return
            }
            guard let json = self.klipData(fra: html),
                  let side = try? JSONDecoder().decode(Sidedata.self, from: Data(json.utf8))
            else {
                DispatchQueue.main.async {
                    self.sidsteFejl = "Siden saa anderledes ud end forventet."
                    self.tegnMenu()
                }
                return
            }
            DispatchQueue.main.async { self.modtag(side) }
        }.resume()
    }

    /// Trækker JSON-objektet ud af "var DATA = {...};" i siden.
    func klipData(fra html: String) -> String? {
        guard let start = html.range(of: "var DATA = ") else { return nil }
        var dybde = 0
        var begyndt = false
        var resultat = ""
        for tegn in html[start.upperBound...] {
            if tegn == "{" { dybde += 1; begyndt = true }
            if begyndt { resultat.append(tegn) }
            if tegn == "}" {
                dybde -= 1
                if dybde == 0 && begyndt { return resultat }
            }
        }
        return nil
    }

    func modtag(_ side: Sidedata) {
        sidsteFejl = nil
        sidstOpdateret = side.opdateret

        let sete = Set(UserDefaults.standard.stringArray(forKey: HUSKE_NOEGLE) ?? [])
        let foersteGang = sete.isEmpty
        let nye = side.boliger.filter { !sete.contains($0.id) }

        boliger = side.boliger
        UserDefaults.standard.set(Array(sete.union(side.boliger.map { $0.id })),
                                  forKey: HUSKE_NOEGLE)
        tegnMenu()

        // Foerste koersel er kun til at laere de nuvaerende boliger at kende.
        guard !foersteGang, !nye.isEmpty else { return }
        givBesked(om: nye)
    }

    // MARK: notifikation

    func givBesked(om nye: [Bolig]) {
        guard maaSendeBesked else { return }

        let indhold = UNMutableNotificationContent()
        if nye.count == 1, let b = nye[0] as Bolig? {
            indhold.title = "Ny bolig: \(b.overskrift)"
            var under = [b.omraade, b.husleje, b.stoerrelse].filter { !$0.isEmpty }
            if b.expat { under.append("kun expats") }
            indhold.body = under.joined(separator: " · ")
            indhold.userInfo = ["url": b.url]
        } else {
            indhold.title = "\(nye.count) nye boliger"
            indhold.body = nye.prefix(3).map { "\($0.overskrift), \($0.husleje)" }
                                        .joined(separator: "\n")
            indhold.userInfo = ["url": SIDE_URL.absoluteString]
        }
        indhold.sound = .default

        let anmodning = UNNotificationRequest(identifier: UUID().uuidString,
                                              content: indhold, trigger: nil)
        UNUserNotificationCenter.current().add(anmodning)
    }

    // Klik paa notifikationen aabner annoncen.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive svar: UNNotificationResponse,
                                withCompletionHandler faerdig: @escaping () -> Void) {
        if let tekst = svar.notification.request.content.userInfo["url"] as? String,
           let url = URL(string: tekst) {
            NSWorkspace.shared.open(url)
        }
        faerdig()
    }

    // Vis ogsaa notifikationen naar appen er den aktive.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent note: UNNotification,
                                withCompletionHandler faerdig:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        faerdig([.banner, .sound])
    }

    // MARK: menu

    func tegnMenu() {
        let menu = NSMenu()

        if let fejl = sidsteFejl {
            let punkt = NSMenuItem(title: "Kunne ikke hente: \(fejl)", action: nil, keyEquivalent: "")
            punkt.isEnabled = false
            menu.addItem(punkt)
        } else {
            let punkt = NSMenuItem(title: "Opdateret \(sidstOpdateret)", action: nil, keyEquivalent: "")
            punkt.isEnabled = false
            menu.addItem(punkt)
        }
        menu.addItem(.separator())

        if boliger.isEmpty && sidsteFejl == nil {
            let punkt = NSMenuItem(title: "Henter boliger…", action: nil, keyEquivalent: "")
            punkt.isEnabled = false
            menu.addItem(punkt)
        }

        for bolig in boliger.prefix(12) {
            let punkt = NSMenuItem(title: bolig.linje,
                                   action: #selector(aabnBolig(_:)), keyEquivalent: "")
            punkt.target = self
            punkt.representedObject = bolig.url
            if bolig.expat || bolig.advarsel {
                punkt.image = NSImage(systemSymbolName: "exclamationmark.triangle",
                                      accessibilityDescription: nil)
            }
            menu.addItem(punkt)
        }
        if boliger.count > 12 {
            let punkt = NSMenuItem(title: "… og \(boliger.count - 12) mere", action: nil, keyEquivalent: "")
            punkt.isEnabled = false
            menu.addItem(punkt)
        }

        menu.addItem(.separator())
        let aabn = NSMenuItem(title: "Åbn hele listen", action: #selector(aabnSiden),
                              keyEquivalent: "o")
        aabn.target = self
        menu.addItem(aabn)

        let opdater = NSMenuItem(title: "Tjek nu", action: #selector(tjekNu), keyEquivalent: "r")
        opdater.target = self
        menu.addItem(opdater)

        menu.addItem(.separator())
        let slut = NSMenuItem(title: "Afslut Boligjagt", action: #selector(afslut), keyEquivalent: "q")
        slut.target = self
        menu.addItem(slut)

        punkt.menu = menu
        punkt.button?.title = boliger.isEmpty ? "" : " \(boliger.count)"
    }

    @objc func aabnBolig(_ afsender: NSMenuItem) {
        if let tekst = afsender.representedObject as? String, let url = URL(string: tekst) {
            NSWorkspace.shared.open(url)
        }
    }
    @objc func aabnSiden() { NSWorkspace.shared.open(SIDE_URL) }
    @objc func tjekNu() { hent() }
    @objc func afslut() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let styring = Styring()
app.delegate = styring
app.setActivationPolicy(.accessory)   // menulinje-app, ingen ikon i Dock
app.run()

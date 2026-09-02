// Boligjagt: et lille macOS-program med eget vindue og et ordmaerke i menulinjen.
//
// Den henter den samme side som telefonen viser, holder styr paa hvilke
// boliger den har set foer, og giver en notifikation naar der kommer en ny.
// Al logikken om at hente og fortolke annoncer ligger i hent.py paa GitHub,
// saa appen behoever kun at laese resultatet.

import AppKit
import WebKit
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

class Styring: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate,
               WKNavigationDelegate, WKUIDelegate, NSWindowDelegate,
               NSToolbarDelegate {

    var punkt: NSStatusItem!
    var ur: Timer?
    var boliger: [Bolig] = []
    var sidstOpdateret = "henter…"
    var sidsteFejl: String?
    var maaSendeBesked = false

    var vindue: NSWindow?
    var web: WKWebView?
    var opdaterKnap: NSButton?
    var statusFelt: NSTextField?

    // MARK: vindue

    /// Aabner appens eget vindue. Siden vises inde i appen, ikke i Safari.
    func visVindue(url: URL? = nil) {
        if vindue == nil {
            let opsaetning = WKWebViewConfiguration()
            opsaetning.websiteDataStore = .default()   // saa localStorage huskes
            let visning = WKWebView(frame: .zero, configuration: opsaetning)
            visning.navigationDelegate = self
            visning.uiDelegate = self
            visning.allowsBackForwardNavigationGestures = true
            web = visning

            let v = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 900),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            v.title = "Boligjagt"
            v.contentView = visning
            v.setFrameAutosaveName("BoligjagtVindue")   // husker stoerrelse og placering
            v.minSize = NSSize(width: 420, height: 480)
            v.delegate = self
            v.isReleasedWhenClosed = false

            let vaerktoej = NSToolbar(identifier: "BoligjagtVaerktoej")
            vaerktoej.delegate = self
            vaerktoej.displayMode = .iconAndLabel
            v.toolbar = vaerktoej
            v.toolbarStyle = .unified

            vindue = v
            visning.load(URLRequest(url: SIDE_URL))
        }
        if let url = url { web?.load(URLRequest(url: url)) }
        vindue?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: vaerktoejslinje

    /// Opdaterer: henter siden igen OG laeser boligerne ind paa ny, saa baade
    /// vinduet og tallet i menulinjen foelger med.
    @objc func opdaterAlt() {
        opdaterKnap?.isEnabled = false
        statusFelt?.stringValue = "Henter…"
        web?.reload()
        hent()
        // Knappen laases kort, saa et utaalmodigt dobbeltklik ikke sender
        // tre hentninger afsted paa en gang.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.opdaterKnap?.isEnabled = true
        }
    }

    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.init("opdater"), .flexibleSpace, .init("status")]
    }
    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(t)
    }

    func toolbar(_ t: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        switch id.rawValue {
        case "opdater":
            let punkt = NSToolbarItem(itemIdentifier: id)
            punkt.label = "Opdater"
            punkt.toolTip = "Hent listen igen (⌘R)"
            let knap = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise",
                                               accessibilityDescription: "Opdater")!,
                                target: self, action: #selector(opdaterAlt))
            knap.bezelStyle = .texturedRounded
            opdaterKnap = knap
            punkt.view = knap
            return punkt
        case "status":
            let punkt = NSToolbarItem(itemIdentifier: id)
            let felt = NSTextField(labelWithString: sidstOpdateret)
            felt.font = .systemFont(ofSize: 11)
            felt.textColor = .secondaryLabelColor
            felt.alignment = .right
            statusFelt = felt
            punkt.view = felt
            return punkt
        default:
            return nil
        }
    }

    /// Klik paa ikonet i Dock naar vinduet er lukket skal aabne det igen.
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { visVindue() }
        return true
    }

    /// Links til selve annoncen aabnes i browseren, hvor hele udbyderens side
    /// fungerer. Vores egen side bliver inde i appen.
    func webView(_ web: WKWebView, decidePolicyFor handling: WKNavigationAction,
                 decisionHandler svar: @escaping (WKNavigationActionPolicy) -> Void) {
        if handling.navigationType == .linkActivated, let url = handling.request.url,
           url.host != SIDE_URL.host {
            NSWorkspace.shared.open(url)
            svar(.cancel)
            return
        }
        svar(.allow)
    }

    /// target="_blank" har ingen mening i et enkelt vindue: aabn i browseren.
    func webView(_ web: WKWebView, createWebViewWith opsaetning: WKWebViewConfiguration,
                 for handling: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = handling.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        byggMenulinje()
        visVindue()
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

    /// Menulinjen oeverst paa skaermen. Uden den virker hverken cmd-Q,
    /// cmd-W eller cmd-R, og appen foeles ikke som et rigtigt program.
    func byggMenulinje() {
        let hoved = NSMenu()

        let appPunkt = NSMenuItem()
        hoved.addItem(appPunkt)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Om Boligjagt", action: #selector(omApp), keyEquivalent: "")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Skjul Boligjagt",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Afslut Boligjagt",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appPunkt.submenu = appMenu

        let visPunkt = NSMenuItem()
        hoved.addItem(visPunkt)
        let visMenu = NSMenu(title: "Vis")
        visMenu.addItem(withTitle: "Opdater listen",
                        action: #selector(opdaterAlt), keyEquivalent: "r").target = self
        visMenu.addItem(withTitle: "Hent siden igen",
                        action: #selector(genindlaes), keyEquivalent: "R").target = self
        visMenu.addItem(.separator())
        visMenu.addItem(withTitle: "Tilbage",
                        action: #selector(tilbage), keyEquivalent: "[").target = self
        visPunkt.submenu = visMenu

        let vinduePunkt = NSMenuItem()
        hoved.addItem(vinduePunkt)
        let vindueMenu = NSMenu(title: "Vindue")
        vindueMenu.addItem(withTitle: "Luk",
                           action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        vindueMenu.addItem(withTitle: "Minimer",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        vinduePunkt.submenu = vindueMenu
        NSApp.windowsMenu = vindueMenu

        NSApp.mainMenu = hoved
    }

    @objc func omApp() {
        let tekst = "Boligjagt holder øje med ledige lejligheder på BoligPortal "
                  + "og Homes and Housing, og skriver en henvendelse klar til dig.\n\n"
                  + "Listen opdateres på GitHub cirka hvert kvarter, også når "
                  + "din Mac er slukket."
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Boligjagt",
            .credits: NSAttributedString(string: tekst),
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func genindlaes() { web?.reload() }
    @objc func tilbage() { web?.goBack() }

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
                    self.statusFelt?.stringValue = "Kunne ikke hente"
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
        statusFelt?.stringValue = "Opdateret \(side.opdateret)"
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
        // Er det en enkelt bolig, aabner vi annoncen i browseren, hvor hele
        // udbyderens side virker. Ellers viser vi vores egen liste i appen.
        if let tekst = svar.notification.request.content.userInfo["url"] as? String,
           let url = URL(string: tekst) {
            if url.host == SIDE_URL.host { visVindue(url: url) }
            else { NSWorkspace.shared.open(url) }
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
    @objc func aabnSiden() { visVindue(url: SIDE_URL) }
    @objc func tjekNu() { hent() }
    @objc func afslut() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let styring = Styring()
app.delegate = styring
app.setActivationPolicy(.regular)     // ikon i Dock og med i cmd-Tab
app.run()

// Tegner appikonet til Boligjagt og skriver et komplet .iconset.
//
// Koeres af byg.sh. Ikonet er et rent ordmaerke: BJAGT paa den samme
// groenne som siden bruger. Under 128 px falder det tilbage til BJ,
// fordi fem bogstaver bliver ulaeselige i Finders mindste stoerrelser.

import AppKit

let groen  = NSColor(srgbRed: 0.141, green: 0.408, blue: 0.353, alpha: 1) // #24685A
let creme  = NSColor(srgbRed: 0.976, green: 0.961, blue: 0.933, alpha: 1) // #F9F5EE

func tegn(_ px: Int) -> Data? {
    // Vi tegner direkte ned i en bitmap i stedet for at gaa gennem NSImage,
    // som fejler paa de mindste stoerrelser.
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    rep.size = NSSize(width: px, height: px)

    let gemt = NSGraphicsContext.current
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    defer { NSGraphicsContext.current = gemt }

    let kant = CGFloat(px)
    let flade = NSRect(x: 0, y: 0, width: kant, height: kant)

    // macOS-ikoner sidder i en afrundet firkant med luft omkring.
    let luft = kant * 0.055
    let plade = flade.insetBy(dx: luft, dy: luft)
    let radius = plade.width * 0.2237      // svarer til Apples afrunding
    let sti = NSBezierPath(roundedRect: plade, xRadius: radius, yRadius: radius)
    groen.setFill()
    sti.fill()

    // Ordmaerket. Faa pixels betyder faerre bogstaver.
    let ord = px >= 128 ? "BJAGT" : "BJ"
    let vaegt: NSFont.Weight = .heavy
    var stoerrelse = px >= 128 ? plade.width * 0.235 : plade.width * 0.46
    var skrift = NSFont.systemFont(ofSize: stoerrelse, weight: vaegt)

    let stil = NSMutableParagraphStyle()
    stil.alignment = .center

    func maal(_ f: NSFont) -> NSSize {
        (ord as NSString).size(withAttributes: [
            .font: f,
            .kern: stoerrelse * (ord.count > 2 ? 0.02 : 0.0),
        ])
    }

    // Skru ned til ordet har luft i begge sider.
    let maxBredde = plade.width * 0.80
    while maal(skrift).width > maxBredde && stoerrelse > 4 {
        stoerrelse -= max(1, stoerrelse * 0.04)
        skrift = NSFont.systemFont(ofSize: stoerrelse, weight: vaegt)
    }

    let egenskaber: [NSAttributedString.Key: Any] = [
        .font: skrift,
        .foregroundColor: creme,
        .paragraphStyle: stil,
        .kern: stoerrelse * (ord.count > 2 ? 0.02 : 0.0),
    ]
    let tekst = NSAttributedString(string: ord, attributes: egenskaber)
    let str = tekst.size()
    tekst.draw(in: NSRect(x: plade.minX,
                          y: plade.midY - str.height / 2,
                          width: plade.width,
                          height: str.height))

    ctx.flushGraphics()
    return rep.representation(using: .png, properties: [:])
}

// --- skriv iconset ---------------------------------------------------------

let maal = CommandLine.arguments.count > 1
         ? CommandLine.arguments[1] : "./Boligjagt.iconset"
try? FileManager.default.createDirectory(atPath: maal,
                                         withIntermediateDirectories: true)

// (navn i iconset, pixels)
let stoerrelser: [(String, Int)] = [
    ("icon_16x16",      16), ("icon_16x16@2x",     32),
    ("icon_32x32",      32), ("icon_32x32@2x",     64),
    ("icon_128x128",   128), ("icon_128x128@2x",  256),
    ("icon_256x256",   256), ("icon_256x256@2x",  512),
    ("icon_512x512",   512), ("icon_512x512@2x", 1024),
]

for (navn, px) in stoerrelser {
    guard let data = tegn(px) else {
        FileHandle.standardError.write(Data("kunne ikke tegne \(navn)\n".utf8))
        exit(1)
    }
    try? data.write(to: URL(fileURLWithPath: "\(maal)/\(navn).png"))
}
print("tegnede \(stoerrelser.count) stoerrelser i \(maal)")

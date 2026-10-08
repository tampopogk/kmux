#!/usr/bin/env swift
// Draws the kmux app icon ("km|ux" in the Kanna palette) with Core Graphics
// and Core Text, so the icon has no binary-only source.
//
//   swift apps/kmux/Icon/make-icon.swift                     # default variant -> apps/kmux/Icon/kmux.icns
//   swift apps/kmux/Icon/make-icon.swift --variant light-row # another variant
//   swift apps/kmux/Icon/make-icon.swift --preview sheet.png # preview sheet of every variant
//   swift apps/kmux/Icon/make-icon.swift --out DIR           # where kmux.icns (and the .iconset) go
//
// Variants: dark-stack (default: the only one whose letters survive at 16 and 32 px),
// dark-row, light-row ("km|ux" in one line; reads best large, smears below 32 px).
//
// Palette: Kanna's UI tokens (kanna-v3 apps/kanna3-mac/Sources/Kanna3Mac/Theme.swift).
// Letters k m u x are warn, bad, machine, accent: the amber -> red -> purple -> blue
// run of Kanna.app's own icon. The "|" is a neutral token (text), as a cursor / split
// divider, so it doesn't compete with the letters (a horizontal split in the stack layout).

import AppKit
import CoreText
import Foundation

// MARK: Palette

struct Palette {
    let bgTop: CGColor, bgBottom: CGColor, edge: CGColor
    let k: CGColor, m: CGColor, u: CGColor, x: CGColor, bar: CGColor
}

func rgb(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255, alpha: a)
}

// Theme.swift: bg 14161a/ffffff, panel 1b1e24/f4f5f7, panel2 22262d/eaecf0, line 2c313a/d8dce2,
// text e6e8eb/1d2026, muted 8b93a0/6b7280, accent 7aa2ff/2f63d8, ok 5fcf93/1f9d5c,
// warn f0b35a/b7791f, bad ef6b6b/cf3f3f, machine b48cff/7c4dcc.
let dark = Palette(bgTop: rgb(0x22262d), bgBottom: rgb(0x14161a), edge: rgb(0xffffff, 0.10),
                   k: rgb(0xf0b35a), m: rgb(0xef6b6b), u: rgb(0xb48cff), x: rgb(0x7aa2ff), bar: rgb(0xe6e8eb))
let light = Palette(bgTop: rgb(0xffffff), bgBottom: rgb(0xeaecf0), edge: rgb(0x000000, 0.10),
                    k: rgb(0xb7791f), m: rgb(0xcf3f3f), u: rgb(0x7c4dcc), x: rgb(0x2f63d8), bar: rgb(0x1d2026))

enum Layout { case row, stack }

struct Variant {
    let name: String, palette: Palette, layout: Layout
}

let variants = [
    Variant(name: "dark-row", palette: dark, layout: .row),
    Variant(name: "light-row", palette: light, layout: .row),
    Variant(name: "dark-stack", palette: dark, layout: .stack),
]

// MARK: Shape

/// Apple's macOS icon grid: on a 1024 canvas the tile is 824 x 824, centred (100 px
/// margin), with a continuous-corner ("squircle") outline of ~185 px corner radius
/// and a soft drop shadow below it.
func tilePath(_ r: CGRect) -> CGPath {
    // Superellipse |x|^n + |y|^n = 1 confined to the corners: straight edges, with
    // continuous-curvature corners of radius `rad` (n = 5 approximates Apple's shape).
    let rad = r.width * 185.4 / 824
    let n = 5.0
    let path = CGMutablePath()
    let corners: [(CGFloat, CGFloat, Double)] = [   // corner centre, start angle
        (r.maxX - rad, r.maxY - rad, 0), (r.minX + rad, r.maxY - rad, .pi / 2),
        (r.minX + rad, r.minY + rad, .pi), (r.maxX - rad, r.minY + rad, 3 * .pi / 2),
    ]
    // Each corner is a quarter superellipse of size 1.28*rad, so the curve eases into the edge.
    let s = rad * 1.28
    var first = true
    for (cx, cy, a0) in corners {
        // Shift the centre so the quarter-curve of size s ends on the edges.
        let ox = cx + (cos(a0 + .pi / 4) > 0 ? -(s - rad) : (s - rad))
        let oy = cy + (sin(a0 + .pi / 4) > 0 ? -(s - rad) : (s - rad))
        for i in 0...48 {
            let t = a0 + Double(i) / 48 * .pi / 2
            let c = cos(t), sn = sin(t)
            let px = ox + s * CGFloat(copysign(pow(abs(c), 2 / n), c))
            let py = oy + s * CGFloat(copysign(pow(abs(sn), 2 / n), sn))
            if first { path.move(to: CGPoint(x: px, y: py)); first = false } else { path.addLine(to: CGPoint(x: px, y: py)) }
        }
    }
    path.closeSubpath()
    return path
}

// MARK: Drawing

func font(_ size: CGFloat, weight: NSFont.Weight) -> CTFont {
    NSFont.monospacedSystemFont(ofSize: size, weight: weight) as CTFont
}

/// Draws one glyph run with its baseline-left at `origin`.
func drawText(_ s: String, _ f: CTFont, _ color: CGColor, at origin: CGPoint, in ctx: CGContext) {
    let attr = NSAttributedString(string: s, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): f,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ])
    let line = CTLineCreateWithAttributedString(attr)
    ctx.textPosition = origin
    CTLineDraw(line, ctx)
}

func advance(_ f: CTFont) -> CGFloat {
    var g: CGGlyph = 0
    var ch: UniChar = 0x6D  // "m"
    CTFontGetGlyphsForCharacters(f, &ch, &g, 1)
    var adv = CGSize.zero
    CTFontGetAdvancesForGlyphs(f, .horizontal, &g, &adv, 1)
    return adv.width
}

/// Snaps a rect to whole device pixels (keeps small sizes crisp).
func snap(_ r: CGRect, _ px: CGFloat) -> CGRect {
    let x0 = (r.minX * px).rounded() / px, y0 = (r.minY * px).rounded() / px
    let x1 = max((r.maxX * px).rounded(), (r.minX * px).rounded() + 1) / px
    let y1 = max((r.maxY * px).rounded(), (r.minY * px).rounded() + 1) / px
    return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
}

/// Draws `v` into a `size` x `size` pixel context. All geometry is in 1024 units.
func render(_ v: Variant, size: Int) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(size) / 1024
    let px = 1 / scale  // one device pixel, in 1024 units
    ctx.scaleBy(x: scale, y: scale)
    ctx.setShouldSmoothFonts(false)
    let p = v.palette
    let small = size <= 32

    // Tile with drop shadow (Apple template: y -12, blur 28, black 30%; omitted at tiny sizes).
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = tilePath(tile)
    ctx.saveGState()
    if !small { ctx.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 28 * scale, color: rgb(0, 0.3)) }
    ctx.addPath(path); ctx.setFillColor(p.bgBottom); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let grad = CGGradient(colorsSpace: cs, colors: [p.bgTop, p.bgBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    ctx.restoreGState()
    // Hairline edge so the tile holds its shape on a matching background.
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    ctx.addPath(path); ctx.setStrokeColor(p.edge); ctx.setLineWidth(max(8, 2 * px)); ctx.strokePath()
    ctx.restoreGState()

    // Small sizes get heavier strokes; Core Text has no hinting, so weight carries legibility.
    let weight: NSFont.Weight = small ? .heavy : .bold
    switch v.layout {
    case .row:
        // "km" | "ux", optically centred on the tile.
        let f = font(small ? 290 : 240, weight: weight)
        let adv = advance(f)
        let gap = adv * 0.62  // the bar's slot
        let total = adv * 4 + gap
        var x = 512 - total / 2
        let xh = CTFontGetXHeight(f), asc = CTFontGetCapHeight(f)
        let base = 512 - xh / 2 - (asc - xh) * 0.2
        for (ch, c) in [("k", p.k), ("m", p.m)] { drawText(ch, f, c, at: CGPoint(x: x, y: base), in: ctx); x += adv }
        let barW = max(adv * 0.16, 1.4 * px)
        let bar = CGRect(x: x + gap / 2 - barW / 2, y: base - xh * 0.42, width: barW, height: asc + xh * 0.78)
        ctx.setFillColor(p.bar); ctx.fill(small ? snap(bar, scale) : bar)
        x += gap
        for (ch, c) in [("u", p.u), ("x", p.x)] { drawText(ch, f, c, at: CGPoint(x: x, y: base), in: ctx); x += adv }
    case .stack:
        // "km" over "ux", the bar as a horizontal split between the rows.
        let f = font(small ? 440 : 360, weight: weight)
        let adv = advance(f)
        let xh = CTFontGetXHeight(f), asc = CTFontGetAscent(f) * 0.74  // ~ascender of "k"
        let x0 = 512 - adv
        let rowGap = xh * 0.62
        // Centre the block from the bottom of "ux" to the top of "k"'s ascender.
        let shift = -(asc - xh) / 2
        func pix(_ v: CGFloat) -> CGFloat { small ? (v * scale).rounded() / scale : v }
        let topBase = pix(512 + rowGap / 2 + shift)
        let botBase = pix(512 - rowGap / 2 - xh + shift)
        drawText("k", f, p.k, at: CGPoint(x: x0, y: topBase), in: ctx)
        drawText("m", f, p.m, at: CGPoint(x: x0 + adv, y: topBase), in: ctx)
        drawText("u", f, p.u, at: CGPoint(x: x0, y: botBase), in: ctx)
        drawText("x", f, p.x, at: CGPoint(x: x0 + adv, y: botBase), in: ctx)
        _ = asc
        let barH = max(xh * 0.11, 1.4 * px)
        let bar = CGRect(x: x0 - adv * 0.05, y: (topBase + botBase + xh) / 2 - barH / 2, width: adv * 2.1, height: barH)
        ctx.setFillColor(p.bar); ctx.fill(small ? snap(bar, scale) : bar)
    }
    return ctx.makeImage()!
}

// MARK: Output

func writePNG(_ img: CGImage, _ url: URL) {
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

func makeIcns(_ v: Variant, outDir: URL) {
    let iconset = outDir.appendingPathComponent("kmux.iconset")
    try? FileManager.default.removeItem(at: iconset)
    try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for pt in [16, 32, 128, 256, 512] {
        writePNG(render(v, size: pt), iconset.appendingPathComponent("icon_\(pt)x\(pt).png"))
        writePNG(render(v, size: pt * 2), iconset.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
    }
    let icns = outDir.appendingPathComponent("kmux.icns")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    p.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
    try! p.run(); p.waitUntilExit()
    guard p.terminationStatus == 0 else { fatalError("iconutil failed") }
    try? FileManager.default.removeItem(at: iconset)
    print("Wrote \(icns.path) (\(v.name))")
}

/// One row per variant: 1024, 128, 32, 16 px at actual size, plus 32 and 16 blown up 8x and 16x
/// (nearest neighbour) so their pixels can be judged.
func makePreview(_ url: URL) {
    let sizes = [1024, 128, 32, 16]
    let pad: CGFloat = 40, rowH: CGFloat = 1024 + 2 * pad, zoom: CGFloat = 8
    let width = pad + 1024 + pad + 128 + pad + 32 + pad + 16 + pad + 32 * zoom + pad + 16 * zoom * 2 + pad
    let height = rowH * CGFloat(variants.count)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for (i, v) in variants.enumerated() {
        let y0 = height - rowH * CGFloat(i + 1)
        // Alternate backdrop so both light and dark Docks are represented.
        ctx.setFillColor(i % 2 == 0 ? rgb(0xd0d4da) : rgb(0x3a3f47))
        ctx.fill(CGRect(x: 0, y: y0, width: width, height: rowH))
        var x = pad
        for s in sizes {
            let img = render(v, size: s)
            ctx.interpolationQuality = .none
            ctx.draw(img, in: CGRect(x: x, y: y0 + pad, width: CGFloat(s), height: CGFloat(s)))
            x += CGFloat(s) + pad
        }
        for s in [32, 16] {
            let z = zoom * CGFloat(32 / s)
            ctx.interpolationQuality = .none
            ctx.draw(render(v, size: s), in: CGRect(x: x, y: y0 + pad, width: CGFloat(s) * z, height: CGFloat(s) * z))
            x += CGFloat(s) * z + pad
        }
        drawText(v.name, font(28, weight: .medium), i % 2 == 0 ? rgb(0x1d2026) : rgb(0xe6e8eb),
                 at: CGPoint(x: 1024 + 2 * pad, y: y0 + rowH - pad - 28), in: ctx)
    }
    writePNG(ctx.makeImage()!, url)
    print("Wrote \(url.path)")
}

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
if let preview = option("--preview") {
    makePreview(URL(fileURLWithPath: preview))
} else {
    let name = option("--variant") ?? "dark-stack"
    guard let v = variants.first(where: { $0.name == name }) else {
        fatalError("unknown variant \(name); one of \(variants.map(\.name))")
    }
    makeIcns(v, outDir: option("--out").map { URL(fileURLWithPath: $0) } ?? scriptDir)
}

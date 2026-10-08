#!/usr/bin/env swift
// Draws the kmux app icon ("km|ux" in the Kanna palette) with Core Graphics
// and Core Text, so the icon has no binary-only source.
//
//   swift apps/kmux/Icon/make-icon.swift                     # default variant -> apps/kmux/Icon/kmux.icns
//   swift apps/kmux/Icon/make-icon.swift --variant light-row # another variant
//   swift apps/kmux/Icon/make-icon.swift --preview sheet.png # preview sheet of every variant
//   swift apps/kmux/Icon/make-icon.swift --out DIR           # where kmux.icns (and the .iconset) go
//   swift apps/kmux/Icon/make-icon.swift --sheet out.png [--only v01,v02]  # contact sheet: 512/64/32/16 px, light + dark
//   swift apps/kmux/Icon/make-icon.swift --zoom out.png [--only v01,v02]   # 32 and 16 px blown up to judge pixels
//
// Variants: dark-stack (default: the only one whose letters survive at 16 and 32 px),
// dark-row, light-row ("km|ux" in one line; reads best large, smears below 32 px).
// v01-v10: explorations for choosing a new icon (see "Explorations" below); selectable with --variant.
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

// MARK: Explorations v01-v10
//
// Ten directions for the user to pick from (layout, the bar, font, background, colour use).
// Each keeps one Kanna colour per letter. Below 64 px each simplifies the way Apple's icons
// do: bigger, heavier letters, no hairlines or highlights, lines snapped to whole pixels.

/// Render state handed to a variant's draw function. The context is already scaled so all
/// geometry is in 1024 units; `px` is one device pixel in those units.
struct R {
    let ctx: CGContext, size: Int
    var scale: CGFloat { CGFloat(size) / 1024 }
    var px: CGFloat { 1024 / CGFloat(size) }
    var small: Bool { size <= 32 }   // Finder / list sizes
    var tiny: Bool { size <= 16 }
    /// Rounds a 1024-unit coordinate to a device pixel at small sizes.
    func pix(_ v: CGFloat) -> CGFloat { small ? (v / px).rounded() * px : v }
    func pix(_ r: CGRect) -> CGRect { small ? snap(r, scale) : r }
    /// A line width of at least `minPx` device pixels.
    func line(_ w: CGFloat, minPx: CGFloat = 1) -> CGFloat { max(w, minPx * px) }
}

let ok = (dark: rgb(0x5fcf93), light: rgb(0x1f9d5c))   // Theme.swift "ok" green
let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)

func sysFont(_ size: CGFloat, _ weight: NSFont.Weight, _ design: NSFontDescriptor.SystemDesign) -> CTFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    let d = base.fontDescriptor.withDesign(design) ?? base.fontDescriptor
    return (NSFont(descriptor: d, size: size) ?? base) as CTFont
}

func glyphPath(_ s: String, _ f: CTFont) -> CGPath {
    var u = Array(s.utf16)
    var g = [CGGlyph](repeating: 0, count: u.count)
    CTFontGetGlyphsForCharacters(f, &u, &g, u.count)
    return CTFontCreatePathForGlyph(f, g[0], nil)!
}

func moved(_ p: CGPath, _ dx: CGFloat, _ dy: CGFloat) -> CGPath {
    var t = CGAffineTransform(translationX: dx, y: dy)
    return p.copy(using: &t)!
}

struct Glyph { let path: CGPath, color: CGColor, letter: String }

/// Lays letters out in rows: each glyph's ink is centred on its column x, rows sit `lead`
/// apart on shared baselines, and the whole block's ink is centred on `centre`.
func grid(_ rows: [[(String, CGColor)]], _ f: CTFont, cols: [CGFloat], lead: CGFloat,
          centre: CGPoint, _ r: R) -> [Glyph] {
    var out: [Glyph] = []
    var box = CGRect.null
    for (i, row) in rows.enumerated() {
        for (j, (ch, c)) in row.enumerated() {
            let p = glyphPath(ch, f)
            let b = p.boundingBoxOfPath
            let q = moved(p, cols[j] - b.midX, -CGFloat(i) * lead)
            box = box.union(q.boundingBoxOfPath)
            out.append(Glyph(path: q, color: c, letter: ch))
        }
    }
    let dx = r.pix(centre.x - box.midX), dy = r.pix(centre.y - box.midY)
    return out.map { Glyph(path: moved($0.path, dx, dy), color: $0.color, letter: $0.letter) }
}

/// Proportional-font rows: glyphs set by their advances plus `tracking`, each row's ink
/// centred on x = 512, rows `lead` apart, the block's ink centred on `centreY`.
func words(_ rows: [[(String, CGColor)]], _ f: CTFont, tracking: CGFloat, lead: CGFloat, centreY: CGFloat, _ r: R) -> [Glyph] {
    var out: [Glyph] = []
    var box = CGRect.null
    for (i, row) in rows.enumerated() {
        var x: CGFloat = 0
        var line: [Glyph] = []
        var lb = CGRect.null
        for (ch, c) in row {
            var u = Array(ch.utf16), g: CGGlyph = 0, adv = CGSize.zero
            CTFontGetGlyphsForCharacters(f, &u, &g, 1)
            CTFontGetAdvancesForGlyphs(f, .horizontal, &g, &adv, 1)
            let q = moved(glyphPath(ch, f), x, -CGFloat(i) * lead)
            lb = lb.union(q.boundingBoxOfPath)
            line.append(Glyph(path: q, color: c, letter: ch))
            x += adv.width + tracking
        }
        for g in line {
            let q = moved(g.path, 512 - lb.midX, 0)
            box = box.union(q.boundingBoxOfPath)
            out.append(Glyph(path: q, color: g.color, letter: g.letter))
        }
    }
    let dy = r.pix(centreY - box.midY)
    return out.map { Glyph(path: moved($0.path, r.small ? r.pix($0.path.boundingBoxOfPath.minX) - $0.path.boundingBoxOfPath.minX : 0, dy), color: $0.color, letter: $0.letter) }
}

/// One glyph whose ink is centred on `c`.
func centred(_ ch: String, _ f: CTFont, _ color: CGColor, at c: CGPoint, _ r: R) -> Glyph {
    let p = glyphPath(ch, f), b = p.boundingBoxOfPath
    return Glyph(path: moved(p, r.pix(c.x - b.midX), r.pix(c.y - b.midY)), color: color, letter: ch)
}

func fill(_ gs: [Glyph], _ r: R) {
    for g in gs { r.ctx.addPath(g.path); r.ctx.setFillColor(g.color); r.ctx.fillPath() }
}

/// Rounded rect with its own radius per corner (tl, tr, br, bl).
func roundRect(_ rc: CGRect, _ tl: CGFloat, _ tr: CGFloat, _ br: CGFloat, _ bl: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: rc.minX + tl, y: rc.maxY))
    p.addArc(tangent1End: CGPoint(x: rc.maxX, y: rc.maxY), tangent2End: CGPoint(x: rc.maxX, y: rc.minY), radius: tr)
    p.addArc(tangent1End: CGPoint(x: rc.maxX, y: rc.minY), tangent2End: CGPoint(x: rc.minX, y: rc.minY), radius: br)
    p.addArc(tangent1End: CGPoint(x: rc.minX, y: rc.minY), tangent2End: CGPoint(x: rc.minX, y: rc.maxY), radius: bl)
    p.addArc(tangent1End: CGPoint(x: rc.minX, y: rc.maxY), tangent2End: CGPoint(x: rc.maxX, y: rc.maxY), radius: tl)
    p.closeSubpath()
    return p
}

func roundRect(_ rc: CGRect, _ rad: CGFloat) -> CGPath { roundRect(rc, rad, rad, rad, rad) }

func vGradient(_ r: R, _ top: CGColor, _ bottom: CGColor, _ rc: CGRect) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [top, bottom] as CFArray, locations: [0, 1])!
    r.ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: rc.maxY), end: CGPoint(x: 0, y: rc.minY),
                             options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

/// The macOS tile: drop shadow, vertical gradient, hairline edge. Leaves the context clipped
/// to the tile (balance with r.ctx.restoreGState()).
func beginTile(_ r: R, _ top: CGColor, _ bottom: CGColor, edge: CGColor, glass: Bool = false) {
    let ctx = r.ctx, path = tilePath(tileRect)
    ctx.saveGState()
    if !r.small { ctx.setShadow(offset: CGSize(width: 0, height: -12 * r.scale), blur: 28 * r.scale, color: rgb(0, 0.3)) }
    ctx.addPath(path); ctx.setFillColor(bottom); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    vGradient(r, top, bottom, tileRect)
    ctx.addPath(path); ctx.setStrokeColor(edge); ctx.setLineWidth(r.line(8, minPx: 2)); ctx.strokePath()
    if glass && !r.small {
        // macOS 26 "Liquid Glass" rim: a bright inner edge at the top that fades downwards.
        ctx.saveGState()
        ctx.addPath(path); ctx.setLineWidth(10); ctx.replacePathWithStrokedPath(); ctx.clip()
        vGradient(r, rgb(0xffffff, 0.55), rgb(0xffffff, 0.0), CGRect(x: 0, y: 512, width: 1024, height: 412))
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path); ctx.setLineWidth(10); ctx.replacePathWithStrokedPath(); ctx.clip()
        vGradient(r, rgb(0xffffff, 0.0), rgb(0xffffff, 0.18), CGRect(x: 0, y: 100, width: 1024, height: 300))
        ctx.restoreGState()
    }
}

/// The 2x2 pane rects inside the tile, with `gap` between them and `inset` from the tile edge.
func panes(inset: CGFloat, gap: CGFloat, _ r: R) -> [CGRect] {
    let a = tileRect.insetBy(dx: inset, dy: inset)
    let mid = CGPoint(x: 512, y: 512)
    let g = r.small ? max(gap, r.px) : gap
    var rects = [
        CGRect(x: a.minX, y: mid.y + g / 2, width: mid.x - g / 2 - a.minX, height: a.maxY - mid.y - g / 2),  // tl
        CGRect(x: mid.x + g / 2, y: mid.y + g / 2, width: a.maxX - mid.x - g / 2, height: a.maxY - mid.y - g / 2),  // tr
        CGRect(x: a.minX, y: a.minY, width: mid.x - g / 2 - a.minX, height: mid.y - g / 2 - a.minY),  // bl
        CGRect(x: mid.x + g / 2, y: a.minY, width: a.maxX - mid.x - g / 2, height: mid.y - g / 2 - a.minY),  // br
    ]
    if r.small { rects = rects.map { r.pix($0) } }
    return rects
}

/// Pane outline whose outer corner follows the tile's corner and inner corners are tight.
func panePath(_ rc: CGRect, index i: Int, outer: CGFloat, inner: CGFloat) -> CGPath {
    switch i {
    case 0: return roundRect(rc, outer, inner, inner, inner)
    case 1: return roundRect(rc, inner, outer, inner, inner)
    case 2: return roundRect(rc, inner, inner, inner, outer)
    default: return roundRect(rc, inner, inner, outer, inner)
    }
}

let kmux = (dark: [("k", dark.k), ("m", dark.m), ("u", dark.u), ("x", dark.x)],
            light: [("k", light.k), ("m", light.m), ("u", light.u), ("x", light.x)])

// v01: two tmux panes side by side: k over m on the left, u over x on the right,
// the bar as the pane divider down the middle.
func v01(_ r: R) {
    let ctx = r.ctx
    beginTile(r, rgb(0x22262d), rgb(0x14161a), edge: rgb(0xffffff, 0.10))
    // Right pane a shade lighter, like an inactive vs active pane.
    ctx.setFillColor(rgb(0xffffff, 0.035)); ctx.fill(CGRect(x: 512, y: 0, width: 512, height: 1024))
    let bw = r.small ? r.px * (r.tiny ? 1 : 2) : 10
    ctx.setFillColor(dark.bar); ctx.fill(r.pix(CGRect(x: 512 - bw / 2, y: 100, width: bw, height: 824)))
    let f = sysFont(r.small ? 400 : 330, r.small ? .heavy : .bold, .monospaced)
    let L = kmux.dark
    let gs = grid([[L[0], L[2]], [L[1], L[3]]], f, cols: [312, 712], lead: r.small ? 360 : 320,
                  centre: CGPoint(x: 512, y: 512), r)
    fill(gs, r)
    ctx.restoreGState()
}

// v02: 2x2 grid of panes, split lines as gaps, one letter per pane.
func v02(_ r: R) {
    let ctx = r.ctx
    beginTile(r, rgb(0x2c313a), rgb(0x1b1e24), edge: rgb(0xffffff, 0.10))
    let ps = panes(inset: r.small ? 0 : 44, gap: r.small ? r.px : 26, r)
    for (i, rc) in ps.enumerated() {
        ctx.saveGState()
        ctx.addPath(panePath(rc, index: i, outer: r.small ? 0 : 150, inner: r.small ? 0 : 36)); ctx.clip()
        vGradient(r, rgb(0x1b1e24), rgb(0x0f1114), rc)
        ctx.restoreGState()
    }
    let f = sysFont(r.small ? 380 : 300, r.small ? .heavy : .bold, .monospaced)
    let L = kmux.dark
    // Each row shares a baseline (k's ascender rises above m), centred in its pane row.
    let gs = grid([[L[0], L[1]]], f, cols: [ps[0].midX, ps[1].midX], lead: 0, centre: CGPoint(x: 512, y: ps[0].midY), r)
        + grid([[L[2], L[3]]], f, cols: [ps[2].midX, ps[3].midX], lead: 0, centre: CGPoint(x: 512, y: ps[2].midY), r)
    fill(gs, r)
    ctx.restoreGState()
}

// v03: four coloured pane tiles, white letters.
func v03(_ r: R) {
    let ctx = r.ctx
    beginTile(r, rgb(0x22262d), rgb(0x14161a), edge: rgb(0xffffff, 0.10))
    let ps = panes(inset: r.small ? 0 : 52, gap: r.small ? r.px : 30, r)
    let f = sysFont(r.small ? 400 : 330, .heavy, .rounded)
    for (i, (_, c)) in kmux.dark.enumerated() {
        let rc = ps[i]
        ctx.saveGState()
        ctx.addPath(panePath(rc, index: i, outer: r.small ? 0 : 140, inner: r.small ? 0 : 44)); ctx.clip()
        ctx.setFillColor(c); ctx.fill(rc)
        if !r.small {   // soft top-light so the panes read as tiles
            vGradient(r, rgb(0xffffff, 0.22), rgb(0x000000, 0.10), rc)
        }
        ctx.restoreGState()
        if r.tiny { continue }   // 16 px: four colour squares are the icon
        // Shared baseline per row: centre the row's ink, not each letter's.
        let row = i < 2 ? [kmux.dark[0], kmux.dark[1]] : [kmux.dark[2], kmux.dark[3]]
        let pair = grid([row.map { ($0.0, rgb(0xffffff)) }], f, cols: [ps[i < 2 ? 0 : 2].midX, ps[i < 2 ? 1 : 3].midX],
                        lead: 0, centre: CGPoint(x: 512, y: rc.midY), r)
        let g = pair[i % 2]
        ctx.saveGState()
        if !r.small { ctx.setShadow(offset: CGSize(width: 0, height: -6 * r.scale), blur: 14 * r.scale, color: rgb(0, 0.25)) }
        ctx.addPath(g.path); ctx.setFillColor(rgb(0xffffff)); ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.restoreGState()
}

// v04: a terminal window: light window chrome, dark screen, km over ux split by a pane
// line, and a green tmux status line along the bottom.
func v04(_ r: R) {
    let ctx = r.ctx
    beginTile(r, rgb(0xffffff), rgb(0xe3e6eb), edge: rgb(0x000000, 0.12))
    let titleH: CGFloat = r.small ? 96 : 120
    let screen = r.pix(CGRect(x: r.small ? 160 : 150, y: r.small ? 160 : 150,
                              width: r.small ? 704 : 724, height: 824 - titleH - (r.small ? 60 : 50)))
    if !r.small {
        for (i, c) in [0xd8dce2, 0xd8dce2, 0xd8dce2].enumerated() {
            ctx.setFillColor(rgb(UInt32(c)))
            ctx.fillEllipse(in: CGRect(x: 196 + CGFloat(i) * 64, y: 924 - titleH / 2 - 20, width: 40, height: 40))
        }
    }
    ctx.saveGState()
    ctx.addPath(roundRect(screen, r.small ? 40 : 64)); ctx.clip()
    vGradient(r, rgb(0x1b1e24), rgb(0x0f1114), screen)
    // tmux status line
    let sh: CGFloat = r.small ? max(64, 2 * r.px) : 64
    ctx.setFillColor(ok.dark); ctx.fill(r.pix(CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: sh)))
    let area = CGRect(x: screen.minX, y: screen.minY + sh, width: screen.width, height: screen.height - sh)
    // Pane split between the rows
    let lw = r.small ? r.px : 8
    if !r.tiny {
    ctx.setFillColor(rgb(0x8b93a0)); ctx.fill(r.pix(CGRect(x: area.minX, y: area.midY - lw / 2, width: area.width, height: lw)))
    }
    let f = sysFont(r.small ? 330 : 270, r.small ? .heavy : .bold, .monospaced)
    let L = kmux.dark
    let top = grid([[L[0], L[1]]], f, cols: [area.midX - 0.2 * area.width, area.midX + 0.2 * area.width], lead: 0,
                   centre: CGPoint(x: area.midX, y: area.midY + area.height / 4), r)
    let bot = grid([[L[2], L[3]]], f, cols: [area.midX - 0.2 * area.width, area.midX + 0.2 * area.width], lead: 0,
                   centre: CGPoint(x: area.midX, y: area.midY - area.height / 4), r)
    fill(top + bot, r)
    ctx.restoreGState()
    ctx.restoreGState()
}

// v05: bold monogram k|x; the bar carries the two middle letters, red over purple.
func v05(_ r: R) {
    let ctx = r.ctx
    beginTile(r, rgb(0x22262d), rgb(0x14161a), edge: rgb(0xffffff, 0.10))
    let f = sysFont(r.small ? 560 : 500, r.small ? .heavy : .bold, .monospaced)
    let k = glyphPath("k", f), x = glyphPath("x", f)
    let kb = k.boundingBoxOfPath, xb = x.boundingBoxOfPath
    let barW: CGFloat = r.small ? 3 * r.px : 64, gap: CGFloat = r.small ? 1.5 * r.px : 44
    let total = kb.width + gap + barW + gap + xb.width
    let x0 = 512 - total / 2
    let base = r.pix(512 - kb.height / 2 + (r.small ? 0 : 0))
    let kg = moved(k, r.pix(x0 - kb.minX), base - kb.minY)
    let xg = moved(x, r.pix(x0 + kb.width + gap + barW + gap - xb.minX), base - xb.minY)
    fill([Glyph(path: kg, color: dark.k, letter: "k"), Glyph(path: xg, color: dark.x, letter: "x")], r)
    // Bar: from below the baseline to the k's ascender, top half red, bottom half purple.
    let bar = r.pix(CGRect(x: x0 + kb.width + gap, y: base - (r.small ? 0 : 40), width: barW, height: kb.height + (r.small ? 0 : 80)))
    ctx.saveGState()
    ctx.addPath(roundRect(bar, r.small ? 0 : barW / 2)); ctx.clip()
    if r.small {
        ctx.setFillColor(dark.m); ctx.fill(CGRect(x: bar.minX, y: r.pix(bar.midY), width: bar.width, height: bar.maxY - r.pix(bar.midY)))
        ctx.setFillColor(dark.u); ctx.fill(CGRect(x: bar.minX, y: bar.minY, width: bar.width, height: r.pix(bar.midY) - bar.minY))
    } else {
        vGradient(r, dark.m, dark.u, bar)
    }
    ctx.restoreGState()
    ctx.restoreGState()
}

/// Stacked "km" over "ux" with a horizontal bar between the rows; shared by v06, v07, v09.
func stack(_ r: R, _ f: CTFont, _ L: [(String, CGColor)], colGap: CGFloat, lead: CGFloat, tracking: CGFloat? = nil) -> (glyphs: [Glyph], barY: CGFloat, left: CGFloat, right: CGFloat) {
    let gs = tracking.map { words([[L[0], L[1]], [L[2], L[3]]], f, tracking: $0, lead: lead, centreY: 512, r) }
        ?? grid([[L[0], L[1]], [L[2], L[3]]], f, cols: [512 - colGap / 2, 512 + colGap / 2], lead: lead,
                centre: CGPoint(x: 512, y: 512), r)
    // The bar sits midway between the bottom of the top row (baseline) and the x-height of the second.
    let m = gs[1].path.boundingBoxOfPath, u = gs[2].path.boundingBoxOfPath
    let all = gs.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath) }
    return (gs, (m.minY + u.maxY) / 2, all.minX, all.maxX)
}

// v06: light: white tile, SF Rounded, light-mode letter colours, green pill bar.
func v06(_ r: R) {
    let ctx = r.ctx
    beginTile(r, rgb(0xffffff), rgb(0xe9ecf0), edge: rgb(0x000000, 0.10))
    let f = sysFont(r.small ? 400 : 340, r.small ? .black : .heavy, .rounded)
    let s = stack(r, f, kmux.light, colGap: 0, lead: r.small ? 370 : 330, tracking: r.small ? 30 : 16)
    fill(s.glyphs, r)
    let h: CGFloat = r.small ? 2 * r.px : 30
    let bar = r.pix(CGRect(x: s.left, y: s.barY - h / 2, width: s.right - s.left, height: h))
    ctx.addPath(roundRect(bar, r.small ? 0 : h / 2)); ctx.setFillColor(ok.light); ctx.fillPath()
    ctx.restoreGState()
}

// v07: outlined letters on near-black; filled again below 64 px where outlines would close up.
func v07(_ r: R) {
    let ctx = r.ctx
    beginTile(r, rgb(0x1b1e24), rgb(0x0c0d10), edge: rgb(0xffffff, 0.10))
    let f = sysFont(r.small ? 420 : 360, r.small ? .heavy : .bold, .monospaced)
    let s = stack(r, f, kmux.dark, colGap: r.small ? 250 : 228, lead: r.small ? 360 : 330)
    if r.size < 64 {
        fill(s.glyphs, r)
    } else {
        for g in s.glyphs {
            ctx.addPath(g.path); ctx.setFillColor(g.color.copy(alpha: 0.14)!); ctx.fillPath()
            ctx.addPath(g.path); ctx.setStrokeColor(g.color); ctx.setLineWidth(r.line(18, minPx: 1.2))
            ctx.setLineJoin(.round); ctx.strokePath()
        }
    }
    let h: CGFloat = r.small ? r.px * (r.tiny ? 1 : 2) : 18
    ctx.setFillColor(dark.bar); ctx.fill(r.pix(CGRect(x: s.left - 6, y: s.barY - h / 2, width: s.right - s.left + 12, height: h)))
    ctx.restoreGState()
}

// v08: macOS 26 glass: indigo-to-ink gradient, two frosted panes (km, ux), glowing letters.
func v08(_ r: R) {
    let ctx = r.ctx
    beginTile(r, rgb(0x3b2f6b), rgb(0x10142a), edge: rgb(0xffffff, 0.14), glass: true)
    if !r.small {   // colour wash from the letter hues behind the glass
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        for (c, p) in [(dark.u, CGPoint(x: 260, y: 820)), (dark.x, CGPoint(x: 820, y: 220)), (dark.m, CGPoint(x: 860, y: 860))] {
            let g = CGGradient(colorsSpace: cs, colors: [c.copy(alpha: 0.35)!, c.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: 520, options: [])
        }
    }
    let inset: CGFloat = r.small ? 40 : 70, gap: CGFloat = r.small ? 2 * r.px : 34
    let a = tileRect.insetBy(dx: inset, dy: inset)
    let topP = r.pix(CGRect(x: a.minX, y: 512 + gap / 2, width: a.width, height: a.maxY - 512 - gap / 2))
    let botP = r.pix(CGRect(x: a.minX, y: a.minY, width: a.width, height: 512 - gap / 2 - a.minY))
    for (i, p) in [topP, botP].enumerated() {
        let path = i == 0 ? roundRect(p, 130, 130, 40, 40) : roundRect(p, 40, 40, 130, 130)
        ctx.saveGState()
        if !r.small { ctx.setShadow(offset: CGSize(width: 0, height: -10 * r.scale), blur: 30 * r.scale, color: rgb(0, 0.35)) }
        ctx.addPath(path); ctx.setFillColor(rgb(0xffffff, r.small ? 0.10 : 0.09)); ctx.fillPath()
        ctx.restoreGState()
        if !r.small {
            ctx.saveGState()
            ctx.addPath(path); ctx.clip()
            vGradient(r, rgb(0xffffff, 0.10), rgb(0xffffff, 0), CGRect(x: 0, y: p.midY, width: 1024, height: p.height / 2))
            ctx.addPath(path); ctx.setLineWidth(6); ctx.replacePathWithStrokedPath(); ctx.clip()
            vGradient(r, rgb(0xffffff, 0.6), rgb(0xffffff, 0.08), p)
            ctx.restoreGState()
        }
    }
    let f = sysFont(r.small ? 380 : 320, r.small ? .heavy : .bold, .rounded)
    let L = kmux.dark
    let top = grid([[L[0], L[1]]], f, cols: [512 - 125, 512 + 125], lead: 0, centre: CGPoint(x: 512, y: topP.midY), r)
    let bot = grid([[L[2], L[3]]], f, cols: [512 - 125, 512 + 125], lead: 0, centre: CGPoint(x: 512, y: botP.midY), r)
    for g in top + bot {
        ctx.saveGState()
        if !r.small { ctx.setShadow(offset: .zero, blur: 40 * r.scale, color: g.color.copy(alpha: 0.75)!) }
        ctx.addPath(g.path); ctx.setFillColor(g.color); ctx.fillPath()
        ctx.restoreGState()
        if !r.small {   // light from above
            ctx.saveGState()
            ctx.addPath(g.path); ctx.clip()
            let b = g.path.boundingBoxOfPath
            vGradient(r, rgb(0xffffff, 0.35), rgb(0xffffff, 0), CGRect(x: b.minX, y: b.midY, width: b.width, height: b.height / 2))
            ctx.restoreGState()
        }
    }
    ctx.restoreGState()
}

// v09: serif (New York black) on warm ink, green bar: editorial rather than terminal.
func v09(_ r: R) {
    let ctx = r.ctx
    beginTile(r, rgb(0x262329), rgb(0x141316), edge: rgb(0xffffff, 0.10))
    let f = sysFont(r.small ? 440 : 380, r.small ? .black : .heavy, .serif)
    let s = stack(r, f, kmux.dark, colGap: 0, lead: r.small ? 360 : 330, tracking: r.small ? 40 : 18)
    fill(s.glyphs, r)
    let h: CGFloat = r.small ? 2 * r.px : 26
    let bar = r.pix(CGRect(x: s.left, y: s.barY - h / 2, width: s.right - s.left, height: h))
    ctx.addPath(roundRect(bar, r.small ? 0 : h / 2)); ctx.setFillColor(ok.dark); ctx.fillPath()
    ctx.restoreGState()
}

// v10: Kanna's sibling: black tile, k m over u x, and a tall green cursor pill as the "|"
// between the columns (Kanna.app's icon has the same green cursor-like pill).
func v10(_ r: R) {
    let ctx = r.ctx
    beginTile(r, rgb(0x1b1e24), rgb(0x08090b), edge: rgb(0xffffff, 0.12), glass: true)
    let f = sysFont(r.small ? 400 : 330, r.small ? .heavy : .bold, .monospaced)
    let L = kmux.dark
    let colGap: CGFloat = r.small ? 330 : 310
    let gs = grid([[L[0], L[1]], [L[2], L[3]]], f, cols: [512 - colGap / 2, 512 + colGap / 2], lead: r.small ? 360 : 330,
                  centre: CGPoint(x: 512, y: 512), r)
    fill(gs, r)
    let all = gs.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath) }
    let w: CGFloat = r.small ? 2 * r.px : 44
    let pill = r.pix(CGRect(x: 512 - w / 2, y: all.minY, width: w, height: all.height))
    ctx.saveGState()
    if !r.small { ctx.setShadow(offset: .zero, blur: 36 * r.scale, color: ok.dark.copy(alpha: 0.6)!) }
    ctx.addPath(roundRect(pill, r.small ? 0 : w / 2)); ctx.setFillColor(ok.dark); ctx.fillPath()
    ctx.restoreGState()
    ctx.restoreGState()
}

let explorations: [Variant] = [
    Variant(name: "v01", palette: dark, layout: .stack, note: "two panes: k/m | u/x, divider bar", draw: v01),
    Variant(name: "v02", palette: dark, layout: .stack, note: "2x2 panes, split lines", draw: v02),
    Variant(name: "v03", palette: dark, layout: .stack, note: "coloured pane tiles, white letters", draw: v03),
    Variant(name: "v04", palette: dark, layout: .stack, note: "terminal window, tmux status line", draw: v04),
    Variant(name: "v05", palette: dark, layout: .row, note: "monogram k|x, red/purple bar", draw: v05),
    Variant(name: "v06", palette: light, layout: .stack, note: "light, SF Rounded, green bar", draw: v06),
    Variant(name: "v07", palette: dark, layout: .stack, note: "outlined letters", draw: v07),
    Variant(name: "v08", palette: dark, layout: .stack, note: "macOS 26 glass panes", draw: v08),
    Variant(name: "v09", palette: dark, layout: .stack, note: "serif (New York), green bar", draw: v09),
    Variant(name: "v10", palette: dark, layout: .stack, note: "green cursor pill between columns", draw: v10),
]

/// Contact sheet: one row per variant, its number, then 512/64/32/16 px at actual size on a
/// light (Finder) and a dark (Dock) backdrop.
func makeSheet(_ names: [String], _ url: URL) {
    let vs = names.compactMap { n in variants.first { $0.name == n } }
    let pad: CGFloat = 36, labelW: CGFloat = 0, labelH: CGFloat = 56
    let half = pad + 512 + pad + 64 + pad + 32 + pad + 16 + pad
    let rowH = labelH + 512 + 2 * pad
    let width = labelW + 2 * half, height = rowH * CGFloat(vs.count)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .none
    for (i, v) in vs.enumerated() {
        let y0 = height - rowH * CGFloat(i + 1)
        for (j, bg) in [(rgb(0xececec), rgb(0x1d2026)), (rgb(0x2b2e33), rgb(0xe6e8eb))].enumerated() {
            let x0 = labelW + CGFloat(j) * half
            ctx.setFillColor(bg.0); ctx.fill(CGRect(x: x0, y: y0, width: half, height: rowH))
            var x = x0 + pad
            for s in [512, 64, 32, 16] {
                let yy = y0 + pad + (s == 512 ? 0 : 512 / 2 - CGFloat(s) / 2)
                ctx.draw(render(v, size: s), in: CGRect(x: x, y: yy, width: CGFloat(s), height: CGFloat(s)))
                x += CGFloat(s) + pad
            }
            if j == 0 {
                drawText("\(v.name)  \(v.note)", font(30, weight: .semibold), bg.1,
                         at: CGPoint(x: x0 + pad, y: y0 + rowH - labelH + 6), in: ctx)
            }
        }
        ctx.setFillColor(rgb(0x888888)); ctx.fill(CGRect(x: 0, y: y0, width: width, height: 2))
    }
    writePNG(ctx.makeImage()!, url)
    print("Wrote \(url.path)")
}

/// Zoomed check: 32 and 16 px blown up 8x / 16x so pixels can be judged.
func makeZoom(_ names: [String], _ url: URL) {
    let vs = names.compactMap { n in variants.first { $0.name == n } }
    let cell: CGFloat = 256, pad: CGFloat = 20
    let width = pad + CGFloat(vs.count) * (cell + pad), height = pad + 2 * (cell + pad)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(rgb(0x808080)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.interpolationQuality = .none
    for (i, v) in vs.enumerated() {
        let x = pad + CGFloat(i) * (cell + pad)
        ctx.draw(render(v, size: 32), in: CGRect(x: x, y: pad + cell + pad, width: cell, height: cell))
        ctx.draw(render(v, size: 16), in: CGRect(x: x, y: pad, width: cell, height: cell))
    }
    writePNG(ctx.makeImage()!, url)
    print("Wrote \(url.path)")
}

// MARK: Variants

enum Layout { case row, stack }

struct Variant {
    let name: String, palette: Palette, layout: Layout
    var note = ""
    /// Exploration variants v01-v10 draw themselves; nil = the original row/stack drawing.
    var draw: ((R) -> Void)? = nil
}

let variants = [
    Variant(name: "dark-row", palette: dark, layout: .row),
    Variant(name: "light-row", palette: light, layout: .row),
    Variant(name: "dark-stack", palette: dark, layout: .stack),
] + explorations

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
    if let draw = v.draw {
        draw(R(ctx: ctx, size: size))
        return ctx.makeImage()!
    }
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
} else if let sheet = option("--sheet") {
    // --sheet out.png [--only v01,v02,...]: contact sheet of the exploration variants.
    let names = option("--only")?.split(separator: ",").map(String.init) ?? explorations.map(\.name)
    makeSheet(names, URL(fileURLWithPath: sheet))
} else if let zoom = option("--zoom") {
    let names = option("--only")?.split(separator: ",").map(String.init) ?? explorations.map(\.name)
    makeZoom(names, URL(fileURLWithPath: zoom))
} else {
    let name = option("--variant") ?? "dark-stack"
    guard let v = variants.first(where: { $0.name == name }) else {
        fatalError("unknown variant \(name); one of \(variants.map(\.name))")
    }
    makeIcns(v, outDir: option("--out").map { URL(fileURLWithPath: $0) } ?? scriptDir)
}

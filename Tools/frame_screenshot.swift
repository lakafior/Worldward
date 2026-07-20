import AppKit
import CoreGraphics
import CoreImage
import CoreText
import Foundation

// ---- args ----
// frame_mock.swift <bezel.png> <screenshot.png> <out.png> <headline> <subhead>
let args = CommandLine.arguments
let bezelPath = args[1]
let shotPath  = args[2]
let outPath   = args[3]
let headline  = args.count > 4 ? args[4] : "Your whole world, one map"
let subhead   = args.count > 5 ? args[5] : "Every country you've touched, on a living map"
let bgPath    = args.count > 6 ? args[6] : "gradient"   // photo path or "gradient"

let CS = CGColorSpaceCreateDeviceRGB()

func loadCG(_ path: String) -> CGImage {
    guard let img = NSImage(contentsOfFile: path),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        FileHandle.standardError.write("failed to load \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    return cg
}

func makeCtx(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
              space: CS, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func rgba(_ cg: CGImage) -> (w: Int, h: Int, data: [UInt8]) {
    let w = cg.width, h = cg.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    data.withUnsafeMutableBytes { p in
        let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: CS,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return (w, h, data)
}

func blurred(_ cg: CGImage, radius: Double) -> CGImage {
    let ci = CIImage(cgImage: cg).clampedToExtent()
    let f = CIFilter(name: "CIGaussianBlur")!
    f.setValue(ci, forKey: kCIInputImageKey)
    f.setValue(radius, forKey: kCIInputRadiusKey)
    let out = f.outputImage!
    let cictx = CIContext(options: nil)
    let extent = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
    return cictx.createCGImage(out, from: extent)!
}

// ---- detect the transparent screen cutout inside the bezel ----
// CGContext pixel space: row 0 = BOTTOM. We stay in this space throughout.
let bezelCG = loadCG(bezelPath)
let (bw, bh, bd) = rgba(bezelCG)
@inline(__always) func alpha(_ x: Int, _ y: Int) -> UInt8 { bd[(y * bw + x) * 4 + 3] }

var rowMin = [Int](repeating: Int.max, count: bh)
var rowMax = [Int](repeating: -1, count: bh)
var colMin = [Int](repeating: Int.max, count: bw)
var colMax = [Int](repeating: -1, count: bw)
for y in 0..<bh {
    for x in 0..<bw where alpha(x, y) > 128 {
        if x < rowMin[y] { rowMin[y] = x }
        if x > rowMax[y] { rowMax[y] = x }
        if y < colMin[x] { colMin[x] = y }
        if y > colMax[x] { colMax[x] = y }
    }
}
// screen = transparent pixels fully enclosed by opaque body on all four sides
var sx0 = bw, sy0 = bh, sx1 = 0, sy1 = 0
for y in 0..<bh {
    for x in 0..<bw where alpha(x, y) < 40 {
        if x > rowMin[y] && x < rowMax[y] && y > colMin[x] && y < colMax[x] {
            if x < sx0 { sx0 = x }; if y < sy0 { sy0 = y }
            if x > sx1 { sx1 = x }; if y > sy1 { sy1 = y }
        }
    }
}
let cut = CGRect(x: sx0, y: sy0, width: sx1 - sx0, height: sy1 - sy0)
FileHandle.standardError.write("bezel \(bw)x\(bh)  cutout x=\(sx0) y=\(sy0) w=\(Int(cut.width)) h=\(Int(cut.height)) aspect=\(String(format: "%.4f", cut.width/cut.height))\n".data(using: .utf8)!)

// ---- build the device image: screenshot aspect-filled into cutout, bezel on top ----
let shotCG = loadCG(shotPath)
let dctx = makeCtx(bw, bh)
dctx.interpolationQuality = .high
dctx.saveGState()
let corner = min(cut.width, cut.height) * 0.055
let path = CGPath(roundedRect: cut, cornerWidth: corner, cornerHeight: corner, transform: nil)
dctx.addPath(path); dctx.clip()
let sAspect = max(cut.width / CGFloat(shotCG.width), cut.height / CGFloat(shotCG.height))
let dw = CGFloat(shotCG.width) * sAspect, dh = CGFloat(shotCG.height) * sAspect
dctx.draw(shotCG, in: CGRect(x: cut.midX - dw/2, y: cut.midY - dh/2, width: dw, height: dh))
dctx.restoreGState()
dctx.draw(bezelCG, in: CGRect(x: 0, y: 0, width: bw, height: bh))
let deviceImg = dctx.makeImage()!

// ---- place device (scaled + tilted) on a canvas-sized transparent layer ----
let CW = 1320, CH = 2868
let deviceWidthFrac: CGFloat = 0.92
let scale = (CGFloat(CW) * deviceWidthFrac) / CGFloat(bw)
let tiltDeg: CGFloat = 4.0
let centerX = CGFloat(CW) * 0.50
let centerY = CGFloat(CH) * 0.385  // from bottom; low enough to bleed off the bottom edge
let pctx = makeCtx(CW, CH)
pctx.interpolationQuality = .high
pctx.saveGState()
pctx.translateBy(x: centerX, y: centerY)
pctx.rotate(by: tiltDeg * .pi / 180)
pctx.scaleBy(x: scale, y: scale)
pctx.draw(deviceImg, in: CGRect(x: -CGFloat(bw)/2, y: -CGFloat(bh)/2, width: CGFloat(bw), height: CGFloat(bh)))
pctx.restoreGState()
let placedImg = pctx.makeImage()!

// ---- final canvas ----
let ctx = makeCtx(CW, CH)
ctx.interpolationQuality = .high

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CS, components: [r, g, b, a])!
}
// brand gradient: sky -> azure -> royal -> indigo (diagonal)
let grad = CGGradient(colorsSpace: CS, colors: [
    rgb(0.35, 0.62, 0.95), rgb(0.24, 0.47, 0.90),
    rgb(0.16, 0.35, 0.83), rgb(0.20, 0.20, 0.55)
] as CFArray, locations: [0.0, 0.42, 0.78, 1.0])!

if bgPath != "gradient", FileManager.default.fileExists(atPath: bgPath) {
    // photo backdrop: aspect-fill (cover) with a light blur so it reads clearly as a photo
    let bg = blurred(loadCG(bgPath), radius: 9)
    let s = max(CGFloat(CW) / CGFloat(bg.width), CGFloat(CH) / CGFloat(bg.height))
    let bwd = CGFloat(bg.width) * s, bhd = CGFloat(bg.height) * s
    ctx.draw(bg, in: CGRect(x: (CGFloat(CW) - bwd)/2, y: (CGFloat(CH) - bhd)/2, width: bwd, height: bhd))
    // light uniform brand tint to unify colour without hiding the photo
    ctx.setFillColor(rgb(0.14, 0.30, 0.74, 0.30))
    ctx.fill(CGRect(x: 0, y: 0, width: CW, height: CH))
    // darken ONLY behind the caption (top) so text stays crisp, photo shows below
    let capScrim = CGGradient(colorsSpace: CS, colors: [
        rgb(0.06, 0.12, 0.32, 0.70), rgb(0.06, 0.12, 0.32, 0.0)
    ] as CFArray, locations: [0.0, 1.0])!
    ctx.drawLinearGradient(capScrim, start: CGPoint(x: 0, y: CH),
                           end: CGPoint(x: 0, y: CGFloat(CH) * 0.66), options: [])
    // gentle floor scrim to ground the device where it bleeds off the bottom
    let floorScrim = CGGradient(colorsSpace: CS, colors: [
        rgb(0.06, 0.10, 0.28, 0.55), rgb(0.06, 0.10, 0.28, 0.0)
    ] as CFArray, locations: [0.0, 1.0])!
    ctx.drawLinearGradient(floorScrim, start: CGPoint(x: 0, y: 0),
                           end: CGPoint(x: 0, y: CGFloat(CH) * 0.22), options: [])
} else {
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: CH), end: CGPoint(x: CW, y: 0), options: [])
}

// soft radial glow behind the device
let glowY = centerY + CGFloat(CH) * 0.12
let glow = CGGradient(colorsSpace: CS, colors: [
    rgb(1, 1, 1, 0.22), rgb(1, 1, 1, 0.0)
] as CFArray, locations: [0.0, 1.0])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: centerX, y: glowY), startRadius: 0,
                       endCenter: CGPoint(x: centerX, y: glowY), endRadius: 900, options: [])

// device with a soft drop shadow (downward = -y in bottom-left space)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -34), blur: 72, color: rgb(0, 0, 0, 0.38))
ctx.draw(placedImg, in: CGRect(x: 0, y: 0, width: CW, height: CH))
ctx.restoreGState()

// ---- caption text ----
func drawCentered(_ s: String, size: CGFloat, weight: NSFont.Weight, color: CGColor,
                  topY: CGFloat, tracking: CGFloat = 0) {
    let font = NSFont.systemFont(ofSize: size, weight: weight) as CTFont
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: tracking]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    var asc: CGFloat = 0, desc: CGFloat = 0, lead: CGFloat = 0
    let width = CGFloat(CTLineGetTypographicBounds(line, &asc, &desc, &lead))
    let x = centerX - width / 2
    let y = CGFloat(CH) - (topY + asc)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 14, color: rgb(0, 0, 0, 0.28))
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}
drawCentered(headline, size: 100, weight: .heavy, color: rgb(1, 1, 1), topY: 205, tracking: -1)
drawCentered(subhead, size: 54, weight: .semibold, color: rgb(1, 1, 1, 0.92), topY: 205 + 150)

// ---- export ----
let outImg = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: outImg)
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: outPath))
FileHandle.standardError.write("wrote \(outPath) (\(CW)x\(CH))\n".data(using: .utf8)!)

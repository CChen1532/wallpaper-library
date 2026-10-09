import Foundation
import CoreGraphics
import ImageIO

let imageURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: 160
      ] as CFDictionary) else { fatalError("Moon first-frame PNG cannot be decoded") }
let width = image.width, height = image.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
    guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return true
}
precondition(rendered && width > 0 && height > 0)
var bright = 0, sampled = 0
// The fixed landscape preset places NASA's lit Moon in the right portion.
// The loading overlay has only a few central glyphs and cannot pass this check.
for y in (height / 5)..<(height * 4 / 5) {
    for x in (width * 3 / 5)..<width {
        let i = (y * width + x) * 4
        if Int(pixels[i]) * 21 + Int(pixels[i + 1]) * 72 + Int(pixels[i + 2]) * 7 >= 3_500 { bright += 1 }
        sampled += 1
    }
}
let fraction = Double(bright) / Double(max(1, sampled))
guard fraction >= 0.06 else {
    fputs("FAIL: first-frame-presented still contains the loading overlay or no lit Moon (lit fraction \(fraction))\n", stderr)
    exit(1)
}
print("PASS: first-frame-presented contains the rendered Moon (lit fraction \(fraction))")

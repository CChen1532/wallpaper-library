import Foundation
import CoreVideo

func runRealtimeChecks(_ c: inout Checker) throws {
    var optional: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &optional)
    guard status == kCVReturnSuccess, let buffer = optional else {
        c.check(false, "合成BGRA缓冲区可创建")
        return
    }
    c.check(true, "合成BGRA缓冲区可创建")
    guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess,
          let base = CVPixelBufferGetBaseAddress(buffer) else {
        c.check(false, "合成BGRA缓冲区可写")
        return
    }
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let bytes = base.assumingMemoryBound(to: UInt8.self)
    let pixels: [[UInt8]] = [[10,20,30,255], [40,50,60,128],
                             [70,80,90,255], [100,110,120,64]]
    for y in 0..<2 { for x in 0..<2 {
        let offset = y * stride + x * 4
        for channel in 0..<4 { bytes[offset + channel] = pixels[y * 2 + x][channel] }
    } }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    c.check(true, "合成BGRA缓冲区可写")
    let rgba = try ScenePixelBufferDecoder.rgba(buffer, expectedWidth: 2, expectedHeight: 2)
    c.check([UInt8](rgba) == [30,20,10,255, 60,50,40,128,
                            90,80,70,255, 120,110,100,64], "实时缓冲区按行跨度转换BGRA为RGBA")
    let wrongSize: Bool
    do { _ = try ScenePixelBufferDecoder.rgba(buffer, expectedWidth: 3, expectedHeight: 2); wrongSize = false }
    catch { wrongSize = true }
    c.check(wrongSize, "实时缓冲区尺寸不匹配拒绝")
    var other: CVPixelBuffer?
    let otherStatus = CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32ARGB, nil, &other)
    if otherStatus == kCVReturnSuccess, let other {
        let wrongFormat: Bool
        do { _ = try ScenePixelBufferDecoder.rgba(other, expectedWidth: 2, expectedHeight: 2); wrongFormat = false }
        catch { wrongFormat = true }
        c.check(wrongFormat, "实时缓冲区未知像素格式拒绝")
    }
}

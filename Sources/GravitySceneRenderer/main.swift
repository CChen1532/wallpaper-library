import AppKit
import MetalKit
import CoreText
import ImageIO
import UniformTypeIdentifiers
import GravitySceneCore

func event(_ name: String, _ fields: [String: Any] = [:]) {
    var data = fields; data["event"] = name
    if let json = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]) {
        FileHandle.standardOutput.write(json + Data([10]))
    }
}
func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
struct Uniforms { var width: UInt32; var height: UInt32; var time: Float; var steps: UInt32 }
enum RenderError: Error { case unavailable(String) }

final class GravityRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let universe: MTLComputePipelineState
    let bloomX: MTLComputePipelineState
    let bloomY: MTLComputePipelineState
    let finish: MTLComputePipelineState
    let present: MTLRenderPipelineState
    let atlas: MTLTexture
    let preset: GravityScene.Preset
    var hdr: MTLTexture!
    var output: MTLTexture!
    var bloomA: MTLTexture!
    var bloomB: MTLTexture!
    var start = CACurrentMediaTime()
    var first = true
    var lastCommand: MTLCommandBuffer?
    let inFlight = DispatchSemaphore(value: 1)

    init(preset: GravityScene.Preset) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw RenderError.unavailable("Metal GPU unavailable")
        }
        self.device = device; self.queue = queue; self.preset = preset
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .appendingPathComponent("WallpaperUI_GravitySceneRenderer.bundle")
        let resources = Bundle(url: sibling) ?? Bundle.module
        guard let sourceURL = resources.url(forResource: "Gravity", withExtension: "metal") else {
            throw RenderError.unavailable("Missing Gravity.metal resource")
        }
        let library = try device.makeLibrary(source: String(contentsOf: sourceURL), options: nil)
        universe = try device.makeComputePipelineState(function: library.makeFunction(name: "universe")!)
        bloomX = try device.makeComputePipelineState(function: library.makeFunction(name: "bloomX")!)
        bloomY = try device.makeComputePipelineState(function: library.makeFunction(name: "bloomY")!)
        finish = try device.makeComputePipelineState(function: library.makeFunction(name: "finish")!)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "fullscreen")
        descriptor.fragmentFunction = library.makeFunction(name: "present")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        present = try device.makeRenderPipelineState(descriptor: descriptor)
        atlas = try Self.makeAtlas(device)
        super.init()
    }

    static func makeAtlas(_ device: MTLDevice) throws -> MTLTexture {
        let width = 2048, height = 1024
        let expressions = [
            "∮∂Ω ω = ∫Ω dω", "∇²φ = 4πGρ", "Rμν − ½Rgμν = 8πGTμν", "∫₀∞ e⁻ˣ² dx = √π/2",
            "iℏ ∂ψ/∂t = Ĥψ", "∇ · E = ρ/ε₀", "eⁱπ + 1 = 0", "ζ(s) = ∑ₙ₌₁∞ n⁻ˢ",
            "∂u/∂t = α∇²u", "∮C F · dr = ∬S ∇×F · dS", "det(A − λI) = 0", "∫ f(x)δ(x−a) dx = f(a)",
            "ds² = gμν dxμ dxν", "d²xμ/dτ² + Γμνρ ẋνẋρ = 0", "limₙ→∞ (1 + 1/n)ⁿ = e", "∇×E = −∂B/∂t",
            "ℱ{f}(ξ) = ∫ f(x)e⁻²πⁱˣξ dx", "∫ₐᵇ f′(x) dx = f(b)−f(a)", "∑ₙ₌₁∞ 1/n² = π²/6", "∂L/∂q − d/dt(∂L/∂q̇) = 0",
            "∇ · B = 0", "H = ∑ pᵢq̇ᵢ − L", "∫Ω ∇·F dV = ∮∂Ω F·n dS", "Γ(z) = ∫₀∞ tᶻ⁻¹e⁻ᵗ dt",
            "[x̂,p̂] = iℏ", "∂²u/∂t² = c²∇²u", "K = det(II)/det(I)", "ℒ{f}(s) = ∫₀∞ e⁻ˢᵗf(t) dt",
            "∫ dx/(1+x²) = arctan x+C", "Dₜρ + ρ∇·v = 0", "∇f = (∂ₓf, ∂ᵧf, ∂zf)", "dS = 0   δ∫ L dt = 0"
        ]
        var pixels = [UInt8](repeating: 0, count: width * height)
        try pixels.withUnsafeMutableBytes { bytes in
            guard let cg = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else {
                throw RenderError.unavailable("Formula atlas")
            }
            cg.setFillColor(gray: 0, alpha: 1); cg.fill(CGRect(x: 0,y: 0,width: width,height: height))
            for (i, text) in expressions.enumerated() {
                let font = CTFontCreateWithName("TimesNewRomanPS-ItalicMT" as CFString, 36, nil)
                let string = NSAttributedString(string: text, attributes: [
                    kCTFontAttributeName as NSAttributedString.Key: font,
                    kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 1, alpha: 1)
                ])
                let line = CTLineCreateWithAttributedString(string)
                let length = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                let scale: CGFloat = min(1.0, 488 / max(length,1))
                cg.saveGState()
                // Texture row zero is the top row after the vertical bitmap flip below.
                cg.translateBy(x: CGFloat(i % 4) * 512 + (512-length*scale)/2,
                               y: CGFloat(7-i/4) * 128 + 49)
                cg.scaleBy(x: scale, y: scale)
                cg.textPosition = .zero; CTLineDraw(line,cg); cg.restoreGState()
            }
        }
        // CGContext bitmap memory is bottom-up for these text coordinates.
        var flipped = pixels
        for y in 0..<height { flipped.replaceSubrange((y*width)..<((y+1)*width), with: pixels[((height-y-1)*width)..<((height-y)*width)]) }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead; descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw RenderError.unavailable("Atlas allocation") }
        flipped.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width) }
        return texture
    }

    func resize(width: Int, height: Int) throws {
        guard width >= 16, height >= 16, width <= 4096, height <= 4096 else { throw RenderError.unavailable("Invalid dimensions") }
        lastCommand?.waitUntilCompleted()
        for (format, isHDR) in [(MTLPixelFormat.rgba16Float,true),(.bgra8Unorm,false)] {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,width: width,height: height,mipmapped: false)
            d.storageMode = isHDR ? .private : .shared; d.usage = [.shaderRead,.shaderWrite]
            guard let t = device.makeTexture(descriptor: d) else { throw RenderError.unavailable("Frame allocation") }
            if isHDR { hdr=t } else { output=t }
        }
        let bloomDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: max(4,width/4), height: max(4,height/4), mipmapped: false)
        bloomDescriptor.storageMode = .private; bloomDescriptor.usage = [.shaderRead,.shaderWrite]
        bloomA = device.makeTexture(descriptor: bloomDescriptor)
        bloomB = device.makeTexture(descriptor: bloomDescriptor)
        guard bloomA != nil, bloomB != nil else { throw RenderError.unavailable("Bloom allocation") }
    }
    func encode(_ buffer: MTLCommandBuffer, time: Float) {
        var uniform = Uniforms(width: UInt32(output.width),height: UInt32(output.height),time: time,steps: UInt32(preset.steps))
        for (pipeline, source, destination, extra) in [
            (universe, hdr!, atlas, Optional<MTLTexture>.none),
            (bloomX, hdr!, bloomA!, nil), (bloomY, bloomA!, bloomB!, nil),
            (finish, hdr!, output!, Optional(bloomB!))
        ] {
            let encoder = buffer.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(source,index: 0); encoder.setTexture(destination,index: 1)
            if let extra { encoder.setTexture(extra,index: 2) }
            encoder.setBytes(&uniform,length: MemoryLayout<Uniforms>.stride,index: 0)
            let target = pipeline === universe ? hdr! : destination
            encoder.dispatchThreads(MTLSize(width: target.width,height: target.height,depth: 1),threadsPerThreadgroup: MTLSize(width: 8,height: 8,depth: 1))
            encoder.endEncoding()
        }
    }

    func render(time: Float) throws -> Double {
        let b = queue.makeCommandBuffer()!; encode(b,time: time); b.commit(); b.waitUntilCompleted()
        if let error = b.error { throw error }
        return (b.gpuEndTime-b.gpuStartTime)*1000
    }
    func save(to path: String) throws {
        lastCommand?.waitUntilCompleted()
        let width=output.width,height=output.height
        var data = Data(count: width*height*4)
        data.withUnsafeMutableBytes { output.getBytes($0.baseAddress!,bytesPerRow: width*4,from: MTLRegionMake2D(0,0,width,height),mipmapLevel: 0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width,height: height,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: width*4,
                                  space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                                  provider: provider,decode: nil,shouldInterpolate: false,intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath:path) as CFURL,UTType.png.identifier as CFString,1,nil) else {
            throw RenderError.unavailable("Snapshot encoding")
        }
        CGImageDestinationAddImage(destination,image,nil)
        guard CGImageDestinationFinalize(destination) else { throw RenderError.unavailable("Snapshot write") }
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        let ratio = size.height/max(size.width,1)
        let width = min(preset.width,Int(size.width))
        do { try resize(width: max(16,width),height: max(16,Int(Double(width)*ratio))) }
        catch { event("error",["message":String(describing:error)]) }
    }
    func draw(in view: MTKView) {
        guard output != nil, inFlight.wait(timeout: .now()) == .success else { return }
        guard let drawable=view.currentDrawable, let pass=view.currentRenderPassDescriptor, let b=queue.makeCommandBuffer() else { inFlight.signal();return }
        encode(b,time: Float(CACurrentMediaTime()-start))
        let e=b.makeRenderCommandEncoder(descriptor: pass)!
        e.setRenderPipelineState(present);e.setFragmentTexture(output,index: 0)
        e.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 3);e.endEncoding();b.present(drawable)
        let signalFirst = first; first=false
        b.addCompletedHandler { [weak self] command in
            if signalFirst && command.status == .completed { event("first-frame-presented") }
            self?.inFlight.signal()
        }
        lastCommand=b;b.commit()
    }
}

final class App: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var renderer: GravityRenderer!
    var view: MTKView!
    var control: DispatchSourceRead?
    var pending=Data()
    let preset = GravityScene.Preset(rawValue: argument("--preset") ?? "ultra") ?? .ultra
    func screen(_ id: UInt32) -> NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            renderer=try GravityRenderer(preset: preset)
            if let export=argument("--export") {
                try exportFrames(export); NSApp.terminate(nil); return
            }
            let targetID=UInt32(argument("--display-id") ?? "0") ?? 0
            guard let screen=screen(targetID) ?? (targetID==0 ? NSScreen.main : nil) else { throw RenderError.unavailable("Display unavailable") }
            let preview=CommandLine.arguments.contains("--preview")
            window=NSWindow(contentRect: preview ? NSRect(x:100,y:100,width:1200,height:750) : screen.frame,
                            styleMask: preview ? [.titled,.closable,.resizable] : .borderless,backing:.buffered,defer:false)
            window.title=preset.title;window.isReleasedWhenClosed=false
            window.backgroundColor = .black
            window.ignoresMouseEvents = !preview
            if !preview {
                window.level=NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow))-1)
                window.collectionBehavior=[.canJoinAllSpaces,.stationary,.ignoresCycle,.fullScreenAuxiliary]
            }
            view=MTKView(frame:window.contentView!.bounds,device:renderer.device)
            view.colorPixelFormat = .bgra8Unorm;view.framebufferOnly=true
            view.preferredFramesPerSecond=preset.fps;view.delegate=renderer
            window.contentView=view
            renderer.mtkView(view,drawableSizeWillChange:view.drawableSize)
            let deferred=CommandLine.arguments.contains("--deferred-show")
            window.alphaValue=deferred ? 0 : 1;window.orderFrontRegardless()
            _ = try renderer.render(time: 0)
            renderer.first = false
            event("scene-ready")
            event("first-frame-presented")
            if CommandLine.arguments.contains("--control-stdin") { startControl() }
            if let seconds=argument("--duration"),let duration=Double(seconds),duration>0 {
                DispatchQueue.main.asyncAfter(deadline:.now()+duration){NSApp.terminate(nil)}
            }
        } catch { event("error",["message":String(describing:error)]);NSApp.terminate(nil) }
    }
    func exportFrames(_ path:String) throws {
        let width=Int(argument("--width") ?? "\(preset.width)") ?? preset.width
        let height=Int(argument("--height") ?? "\(width*10/16)") ?? width*10/16
        let frames=min(600,max(1,Int(argument("--frames") ?? "1") ?? 1))
        try renderer.resize(width:width,height:height)
        var timings:[Double]=[]
        for i in 0..<(frames+5) {
            let ms=try renderer.render(time:Float(i)/30+12)
            if i>=5{timings.append(ms)}
        }
        try renderer.save(to:path)
        timings.sort()
        let report:[String:Any]=["preset":preset.rawValue,"device":renderer.device.name,"width":width,"height":height,"frames":frames,
                                "gpuMedianMs":timings[timings.count/2],"gpuP95Ms":timings[min(timings.count-1,Int(Double(timings.count)*0.95))]]
        event("export-done",report)
        if let reportPath=argument("--report") { try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:reportPath)) }
    }
    func startControl() {
        let source=DispatchSource.makeReadSource(fileDescriptor:STDIN_FILENO,queue:.main)
        source.setEventHandler { [weak self] in
            guard let self else{return}
            let data=FileHandle.standardInput.availableData
            if data.isEmpty{NSApp.terminate(nil);return}
            self.pending.append(data)
            if self.pending.count>1_048_576 { NSApp.terminate(nil);return }
            while let newline=self.pending.firstIndex(of:10) {
                let line=Data(self.pending[..<newline]);self.pending.removeSubrange(...newline)
                if let object=try? JSONSerialization.jsonObject(with:line) as? [String:Any] { self.command(object) }
            }
        }
        control=source;source.resume()
    }
    func command(_ object:[String:Any]) {
        switch object["cmd"] as? String {
        case "activate":window.alphaValue=1;window.orderFrontRegardless();event("activated")
        case "deactivate":window.alphaValue=0;event("deactivated")
        case "quit":NSApp.terminate(nil)
        case "moveDisplay":
            if let number=object["displayID"] as? NSNumber,let screen=screen(number.uint32Value) {
                window.setFrame(screen.frame,display:true);event("display-moved",["display_id":number.uint32Value])
            }
        case "snapshot":
            guard let path=object["path"] as? String,let token=object["token"] as? String else{return}
            do { try renderer.save(to:path);event("snapshot-done",["token":token,"ok":true]) }
            catch{event("snapshot-done",["token":token,"ok":false])}
        default:break
        }
    }
    func applicationWillTerminate(_ notification:Notification) { view?.isPaused=true;control?.cancel();window?.orderOut(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{true}
}
if let outputPath = argument("--export") {
    let exporter = App()
    do {
        exporter.renderer = try GravityRenderer(preset: exporter.preset)
        try exporter.exportFrames(outputPath)
        exit(0)
    } catch {
        event("error", ["message": String(describing: error)])
        exit(1)
    }
}
let application=NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate=App();application.delegate=delegate
application.run()

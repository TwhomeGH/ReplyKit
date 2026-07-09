import Metal
import CoreVideo
import CoreText
import UIKit

final class PIPMetalRenderer {
    static let shared = PIPMetalRenderer()

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let textureCache: CVMetalTextureCache
    let pipelineState: MTLRenderPipelineState

    private var textTextureCache: [String: (texture: MTLTexture, w: Int, h: Int)] = [:]

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            sendlog(message: "Metal init failed")
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue

        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache = cache else {
            sendlog(message: "CVMetalTextureCache create failed: \(status)")
            return nil
        }
        self.textureCache = cache

        guard let lib = try? device.makeDefaultLibrary(bundle: .main),
              let vertexFn = lib.makeFunction(name: "vertex_quad"),
              let fragmentFn = lib.makeFunction(name: "fragment_texture") else {
            sendlog(message: "Metal shaders not found")
            return nil
        }

        let pDesc = MTLRenderPipelineDescriptor()
        pDesc.vertexFunction = vertexFn
        pDesc.fragmentFunction = fragmentFn
        pDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pDesc.colorAttachments[0].isBlendingEnabled = true
        pDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pDesc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        pDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let ps = try? device.makeRenderPipelineState(descriptor: pDesc) else {
            sendlog(message: "Metal pipeline state failed")
            return nil
        }
        self.pipelineState = ps
    }

    func clearTextCache() { textTextureCache.removeAll() }

    // MARK: - Main Render

    func render(pixelBuffer: CVPixelBuffer, renderData: PIPRenderData) {
        let pw = CVPixelBufferGetWidth(pixelBuffer)
        let ph = CVPixelBufferGetHeight(pixelBuffer)
        let scale = UIScreen.main.scale

        var cvTex: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .bgra8Unorm, pw, ph, 0, &cvTex) == kCVReturnSuccess,
              let cvTex = cvTex,
              let destTex = CVMetalTextureGetTexture(cvTex) else { return }

        guard let cmdBuf = commandQueue.makeCommandBuffer(),
              let enc = cmdBuf.makeRenderCommandEncoder(
                descriptor: descriptor(texture: destTex, clear: true)) else { return }

        enc.setRenderPipelineState(pipelineState)

        // draw text items
        for item in renderData.textItems {
            drawText(encoder: enc, text: item.text, font: item.font, color: item.color,
                     x: item.point.x * scale,
                     y: CGFloat(ph) - item.point.y * scale - ceil(item.font.lineHeight * scale),
                     pixelW: pw, pixelH: ph, alpha: item.alpha)
        }

        // draw image items
        for item in renderData.imageItems {
            drawImage(encoder: enc, image: item.image,
                      frame: CGRect(x: item.frame.minX * scale,
                                    y: CGFloat(ph) - item.frame.minY * scale - item.frame.height * scale,
                                    width: item.frame.width * scale,
                                    height: item.frame.height * scale),
                      pixelW: pw, pixelH: ph, alpha: item.alpha,
                      cornerRadius: item.cornerRadius * scale)
        }

        enc.endEncoding()
        cmdBuf.commit()
    }

    // MARK: - Internal

    private func descriptor(texture: MTLTexture, clear: Bool) -> MTLRenderPassDescriptor {
        let d = MTLRenderPassDescriptor()
        d.colorAttachments[0].texture = texture
        d.colorAttachments[0].loadAction = clear ? .clear : .load
        d.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        return d
    }

    private func textTexture(_ string: String, font: UIFont, color: UIColor, scale: CGFloat) -> (texture: MTLTexture, w: Int, h: Int)? {
        let scaledFont = font.withSize(font.pointSize * scale)
        let k = "\(string)|\(scaledFont.fontName)|\(scaledFont.pointSize)|\(color.hexString ?? "white")"
        if let cached = textTextureCache[k] { return cached }

        let attrs: [NSAttributedString.Key: Any] = [.font: scaledFont, .foregroundColor: color]
        let s = (string as NSString).size(withAttributes: attrs)
        let w = max(Int(ceil(s.width)), 1)
        let h = max(Int(ceil(s.height)), 1)

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &pixels, width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        ctx?.clear(CGRect(x: 0, y: 0, width: w, height: h))
        UIGraphicsPushContext(ctx!)
        (string as NSString).draw(at: .zero, withAttributes: attrs)
        UIGraphicsPopContext()

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        td.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: td) else { return nil }
        pixels.withUnsafeBytes { tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 4) }

        textTextureCache[k] = (tex, w, h)
        return (tex, w, h)
    }

    private func drawText(encoder: MTLRenderCommandEncoder, text: String, font: UIFont, color: UIColor,
                          x: CGFloat, y: CGFloat, pixelW: Int, pixelH: Int, alpha: CGFloat) {
        guard alpha > 0.01, let info = textTexture(text, font: font, color: color, scale: UIScreen.main.scale) else { return }
        let (tw, th) = (CGFloat(info.w), CGFloat(info.h))
        let verts = quadVerts(x: x, y: y, w: tw, h: th, pw: CGFloat(pixelW), ph: CGFloat(pixelH), alpha: alpha)
        drawQuad(encoder: encoder, verts: verts, texture: info.texture)
    }

    private func drawImage(encoder: MTLRenderCommandEncoder, image: UIImage?,
                           frame: CGRect, pixelW: Int, pixelH: Int, alpha: CGFloat, cornerRadius: CGFloat) {
        guard alpha > 0.01, let img = image, let cgImg = img.cgImage else { return }
        let w = Int(frame.width)
        let h = Int(frame.height)
        guard w > 0, h > 0 else { return }

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &pixels, width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        if cornerRadius > 0 {
            ctx?.addPath(UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerRadius: cornerRadius).cgPath)
            ctx?.clip()
        }
        ctx?.draw(cgImg, in: CGRect(x: 0, y: 0, width: w, height: h))

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        td.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: td) else { return }
        pixels.withUnsafeBytes { tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 4) }

        let verts = quadVerts(x: frame.minX, y: frame.minY, w: frame.width, h: frame.height, pw: CGFloat(pixelW), ph: CGFloat(pixelH), alpha: alpha)
        drawQuad(encoder: encoder, verts: verts, texture: tex)
    }

    private func quadVerts(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, pw: CGFloat, ph: CGFloat, alpha: CGFloat) -> [Float] {
        let l = Float(x / pw * 2 - 1)
        let r = Float((x + w) / pw * 2 - 1)
        let b = Float(y / ph * 2 - 1)
        let t = Float((y + h) / ph * 2 - 1)
        let a = Float(alpha)
        // position.x, position.y, texCoord.x, texCoord.y, alpha
        return [
            l, b, 0, 0, a,
            r, b, 1, 0, a,
            l, t, 0, 1, a,
            r, t, 1, 1, a,
        ]
    }

    private func drawQuad(encoder: MTLRenderCommandEncoder, verts: [Float], texture: MTLTexture) {
        var v = verts
        let indices: [UInt16] = [0, 1, 2, 1, 3, 2]
        let vb = device.makeBuffer(bytes: &v, length: v.count * MemoryLayout<Float>.size, options: .storageModeShared)!
        let ib = device.makeBuffer(bytes: indices, length: indices.count * MemoryLayout<UInt16>.size, options: .storageModeShared)!
        encoder.setVertexBuffer(vb, offset: 0, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: 6, indexType: .uint16, indexBuffer: ib, indexBufferOffset: 0)
    }
}

private extension UIColor {
    var hexString: String? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return String(format: "%02x%02x%02x", Int(r*255), Int(g*255), Int(b*255))
    }
}

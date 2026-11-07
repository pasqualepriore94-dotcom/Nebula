import MetalKit
import MetalFX
import MetalPerformanceShaders
import QuartzCore

enum RendererError: Error {
    case noLibrary
    case noFunction(String)
    case noBuffer
}

/// Renderer Metal: HDR, particelle su GPU, bloom, tone mapping ACES e upscaling MetalFX.
final class Renderer: NSObject, MTKViewDelegate {
    static let framesInFlight = 3
    static let particleCapacity = 131_072
    static let maxInstances = 2048
    static let maxSprites = 8192
    static let maxSpawns = 16_384

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let game: Game
    private let semaphore = DispatchSemaphore(value: Renderer.framesInFlight)
    private var frameIndex = 0

    private let meshPipeline: MTLRenderPipelineState
    private let bgPipeline: MTLRenderPipelineState
    private let spritePipeline: MTLRenderPipelineState
    private let particlePipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let spawnPSO: MTLComputePipelineState
    private let updatePSO: MTLComputePipelineState
    private let brightPSO: MTLComputePipelineState
    private let downPSO: MTLComputePipelineState
    private let depthWrite: MTLDepthStencilState
    private let depthRead: MTLDepthStencilState
    private let depthAlways: MTLDepthStencilState

    private let meshBuffers: [MTLBuffer]
    private let meshVertexCounts: [Int]
    private let uniformBuffers: [MTLBuffer]
    private let instanceBuffers: [MTLBuffer]
    private let spriteBuffers: [MTLBuffer]
    private let spawnBuffers: [MTLBuffer]
    private let particleBuffer: MTLBuffer
    private var particleRing = 0

    private let blurSmall: MPSImageGaussianBlur
    private let blurLarge: MPSImageGaussianBlur

    private var sceneTex: MTLTexture?
    private var depthTex: MTLTexture?
    private var bloomA: MTLTexture?
    private var bloomB: MTLTexture?
    private var bloomC: MTLTexture?
    private var bloomD: MTLTexture?
    private var outputTex: MTLTexture?
    private var upscaledTex: MTLTexture?
    private var scaler: MTLFXSpatialScaler?
    private var renderWidth = 0
    private var renderHeight = 0

    private var lastTime = CACurrentMediaTime()
    private var frame = FrameData()

    init(view: MTKView, game: Game) throws {
        guard let device = view.device, let queue = device.makeCommandQueue() else { throw RendererError.noBuffer }
        self.device = device
        self.queue = queue
        self.game = game

        guard let library = device.makeDefaultLibrary() else { throw RendererError.noLibrary }
        func fn(_ name: String) throws -> MTLFunction {
            guard let f = library.makeFunction(name: name) else { throw RendererError.noFunction(name) }
            return f
        }
        func render(_ v: String, _ f: String, color: MTLPixelFormat, depth: MTLPixelFormat, additive: Bool) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = try fn(v)
            d.fragmentFunction = try fn(f)
            d.colorAttachments[0].pixelFormat = color
            d.depthAttachmentPixelFormat = depth
            if additive {
                let a = d.colorAttachments[0]!
                a.isBlendingEnabled = true
                a.rgbBlendOperation = .add
                a.alphaBlendOperation = .add
                a.sourceRGBBlendFactor = .one
                a.destinationRGBBlendFactor = .one
                a.sourceAlphaBlendFactor = .one
                a.destinationAlphaBlendFactor = .one
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }

        meshPipeline = try render("meshVertex", "meshFragment", color: .rgba16Float, depth: .depth32Float, additive: false)
        bgPipeline = try render("fullscreenVertex", "backgroundFragment", color: .rgba16Float, depth: .depth32Float, additive: false)
        spritePipeline = try render("spriteVertex", "spriteFragment", color: .rgba16Float, depth: .depth32Float, additive: true)
        particlePipeline = try render("particleVertex", "spriteFragment", color: .rgba16Float, depth: .depth32Float, additive: true)
        compositePipeline = try render("fullscreenVertex", "compositeFragment", color: .bgra8Unorm, depth: .invalid, additive: false)

        spawnPSO = try device.makeComputePipelineState(function: try fn("particleSpawn"))
        updatePSO = try device.makeComputePipelineState(function: try fn("particleUpdate"))
        brightPSO = try device.makeComputePipelineState(function: try fn("bloomBright"))
        downPSO = try device.makeComputePipelineState(function: try fn("bloomDown"))

        func depthState(_ compare: MTLCompareFunction, write: Bool) throws -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = compare
            d.isDepthWriteEnabled = write
            guard let s = device.makeDepthStencilState(descriptor: d) else { throw RendererError.noBuffer }
            return s
        }
        depthWrite = try depthState(.less, write: true)
        depthRead = try depthState(.less, write: false)
        depthAlways = try depthState(.always, write: false)

        // mesh, nell'ordine di MeshKind
        let meshData: [[Vertex]] = [Meshes.player(), Meshes.fighter(), Meshes.drone(), Meshes.asteroid()]
        var mb: [MTLBuffer] = []
        for data in meshData {
            guard let b = device.makeBuffer(bytes: data, length: MemoryLayout<Vertex>.stride * data.count, options: .storageModeShared) else {
                throw RendererError.noBuffer
            }
            mb.append(b)
        }
        meshBuffers = mb
        meshVertexCounts = meshData.map { $0.count }

        func buffers(_ length: Int) throws -> [MTLBuffer] {
            var out: [MTLBuffer] = []
            for _ in 0..<Renderer.framesInFlight {
                guard let b = device.makeBuffer(length: length, options: .storageModeShared) else { throw RendererError.noBuffer }
                out.append(b)
            }
            return out
        }
        uniformBuffers = try buffers(MemoryLayout<FrameUniforms>.stride)
        instanceBuffers = try buffers(MemoryLayout<MeshInstance>.stride * Renderer.maxInstances)
        spriteBuffers = try buffers(MemoryLayout<Sprite>.stride * Renderer.maxSprites)
        spawnBuffers = try buffers(MemoryLayout<Particle>.stride * Renderer.maxSpawns)

        let pLen = MemoryLayout<Particle>.stride * Renderer.particleCapacity
        guard let pb = device.makeBuffer(length: pLen, options: .storageModeShared) else { throw RendererError.noBuffer }
        memset(pb.contents(), 0, pLen)
        particleBuffer = pb

        blurSmall = MPSImageGaussianBlur(device: device, sigma: 3)
        blurSmall.edgeMode = .clamp
        blurLarge = MPSImageGaussianBlur(device: device, sigma: 7)
        blurLarge.edgeMode = .clamp

        super.init()
        buildTextures(drawableSize: view.drawableSize)
    }

    // MARK: - Texture

    private func makeTexture(_ format: MTLPixelFormat, _ w: Int, _ h: Int, _ usage: MTLTextureUsage,
                             _ storage: MTLStorageMode = .private) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: max(1, w), height: max(1, h), mipmapped: false)
        d.usage = usage
        d.storageMode = storage
        return device.makeTexture(descriptor: d)
    }

    private func buildTextures(drawableSize: CGSize) {
        let outW = Int(drawableSize.width)
        let outH = Int(drawableSize.height)
        guard outW > 0, outH > 0 else { return }

        // Rendering a risoluzione ridotta + upscaling MetalFX, se disponibile
        var w = outW, h = outH
        scaler = nil
        if MTLFXSpatialScalerDescriptor.supportsDevice(device) {
            let sw = Int(Float(outW) * 0.7), sh = Int(Float(outH) * 0.7)
            let desc = MTLFXSpatialScalerDescriptor()
            desc.inputWidth = sw
            desc.inputHeight = sh
            desc.outputWidth = outW
            desc.outputHeight = outH
            desc.colorTextureFormat = .bgra8Unorm
            desc.outputTextureFormat = .bgra8Unorm
            desc.colorProcessingMode = .perceptual
            if let s = desc.makeSpatialScaler(device: device) {
                scaler = s
                w = sw
                h = sh
            }
        }
        renderWidth = w
        renderHeight = h

        sceneTex = makeTexture(.rgba16Float, w, h, [.renderTarget, .shaderRead])
        depthTex = makeTexture(.depth32Float, w, h, [.renderTarget], .memoryless)
        bloomA = makeTexture(.rgba16Float, w / 2, h / 2, [.shaderRead, .shaderWrite])
        bloomB = makeTexture(.rgba16Float, w / 2, h / 2, [.shaderRead, .shaderWrite])
        bloomC = makeTexture(.rgba16Float, w / 4, h / 4, [.shaderRead, .shaderWrite])
        bloomD = makeTexture(.rgba16Float, w / 4, h / 4, [.shaderRead, .shaderWrite])

        if let s = scaler {
            outputTex = makeTexture(.bgra8Unorm, w, h, s.colorTextureUsage.union([.renderTarget, .shaderRead]))
            upscaledTex = makeTexture(.bgra8Unorm, outW, outH, s.outputTextureUsage)
        } else {
            outputTex = makeTexture(.bgra8Unorm, w, h, [.renderTarget, .shaderRead])
            upscaledTex = nil
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        buildTextures(drawableSize: size)
    }

    // MARK: - Disegno

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - lastTime, 0), 1.0 / 30.0))
        lastTime = now

        game.update(dt: dt)

        guard let sceneTex = sceneTex, let depthTex = depthTex,
              let bloomA = bloomA, let bloomB = bloomB, let bloomC = bloomC, let bloomD = bloomD,
              let outputTex = outputTex else {
            game.particleSpawns.removeAll(keepingCapacity: true)
            return
        }

        semaphore.wait()
        guard let cmd = queue.makeCommandBuffer() else {
            semaphore.signal()
            return
        }
        let sem = semaphore
        cmd.addCompletedHandler { _ in sem.signal() }

        let fi = frameIndex
        frameIndex = (frameIndex + 1) % Renderer.framesInFlight

        game.buildFrame(&frame)

        // --- uniform ---
        let aspect = Float(renderWidth) / Float(max(renderHeight, 1))
        let eye = SIMD3<Float>(frame.shake.x, -9 + frame.shake.y, 27)
        let center = SIMD3<Float>(frame.shake.x * 0.5, 0.5, 0)
        let viewMatrix = float4x4.lookAt(eye: eye, center: center, up: SIMD3<Float>(0, 1, 0))
        let proj = float4x4.perspective(fovy: 52 * .pi / 180, aspect: aspect, near: 1, far: 200)
        let light = normalize(SIMD3<Float>(0.4, 0.6, 0.7))
        var u = FrameUniforms(viewProj: proj * viewMatrix, view: viewMatrix, proj: proj,
                              cameraPos: SIMD4<Float>(eye.x, eye.y, eye.z, 1),
                              lightDir: SIMD4<Float>(light.x, light.y, light.z, 0),
                              params: SIMD4<Float>(frame.time, frame.scroll, aspect, 0),
                              post: SIMD4<Float>(frame.flash, frame.aberration, 0.95, Float(Int(frame.time * 60) % 997)))
        memcpy(uniformBuffers[fi].contents(), &u, MemoryLayout<FrameUniforms>.stride)

        // --- istanze mesh ---
        var instanceOffsets = [Int](repeating: 0, count: MeshKind.allCases.count)
        var instanceCounts = [Int](repeating: 0, count: MeshKind.allCases.count)
        var written = 0
        let instPtr = instanceBuffers[fi].contents().bindMemory(to: MeshInstance.self, capacity: Renderer.maxInstances)
        for k in 0..<frame.instances.count {
            let list = frame.instances[k]
            let n = min(list.count, Renderer.maxInstances - written)
            instanceOffsets[k] = written
            instanceCounts[k] = n
            if n > 0 {
                list.withUnsafeBufferPointer { src in
                    (instPtr + written).update(from: src.baseAddress!, count: n)
                }
                written += n
            }
        }

        // --- sprite ---
        let spriteCount = min(frame.sprites.count, Renderer.maxSprites)
        if spriteCount > 0 {
            let sp = spriteBuffers[fi].contents().bindMemory(to: Sprite.self, capacity: Renderer.maxSprites)
            frame.sprites.withUnsafeBufferPointer { src in
                sp.update(from: src.baseAddress!, count: spriteCount)
            }
        }

        // --- nuove particelle ---
        let spawnCount = min(game.particleSpawns.count, Renderer.maxSpawns)
        if spawnCount > 0 {
            let pp = spawnBuffers[fi].contents().bindMemory(to: Particle.self, capacity: Renderer.maxSpawns)
            game.particleSpawns.withUnsafeBufferPointer { src in
                pp.update(from: src.baseAddress!, count: spawnCount)
            }
        }
        game.particleSpawns.removeAll(keepingCapacity: true)

        // 1. Simulazione particelle (compute)
        if let ce = cmd.makeComputeCommandEncoder() {
            if spawnCount > 0 {
                ce.setComputePipelineState(spawnPSO)
                ce.setBuffer(particleBuffer, offset: 0, index: 0)
                ce.setBuffer(spawnBuffers[fi], offset: 0, index: 1)
                var info = SIMD4<UInt32>(UInt32(particleRing), UInt32(spawnCount), UInt32(Renderer.particleCapacity), 0)
                ce.setBytes(&info, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 2)
                dispatch1D(ce, spawnPSO, spawnCount)
                particleRing = (particleRing + spawnCount) % Renderer.particleCapacity
            }
            ce.setComputePipelineState(updatePSO)
            ce.setBuffer(particleBuffer, offset: 0, index: 0)
            var sim = SIMD4<Float>(dt, 1.6, 2.5, Float(Renderer.particleCapacity))
            ce.setBytes(&sim, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
            dispatch1D(ce, updatePSO, Renderer.particleCapacity)
            ce.endEncoding()
        }

        // 2. Scena HDR
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = sceneTex
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rp.colorAttachments[0].storeAction = .store
        rp.depthAttachment.texture = depthTex
        rp.depthAttachment.loadAction = .clear
        rp.depthAttachment.clearDepth = 1
        rp.depthAttachment.storeAction = .dontCare

        if let re = cmd.makeRenderCommandEncoder(descriptor: rp) {
            let ub = uniformBuffers[fi]

            // sfondo: nebulosa e stelle procedurali
            re.setRenderPipelineState(bgPipeline)
            re.setDepthStencilState(depthAlways)
            re.setFragmentBuffer(ub, offset: 0, index: 0)
            re.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

            // mesh 3D illuminate
            re.setRenderPipelineState(meshPipeline)
            re.setDepthStencilState(depthWrite)
            re.setCullMode(.none)
            re.setVertexBuffer(instanceBuffers[fi], offset: 0, index: 1)
            re.setVertexBuffer(ub, offset: 0, index: 2)
            re.setFragmentBuffer(ub, offset: 0, index: 0)
            for k in 0..<meshBuffers.count where instanceCounts[k] > 0 {
                re.setVertexBuffer(meshBuffers[k], offset: 0, index: 0)
                re.setVertexBufferOffset(instanceOffsets[k] * MemoryLayout<MeshInstance>.stride, index: 1)
                re.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: meshVertexCounts[k], instanceCount: instanceCounts[k])
            }

            // particelle GPU (additive)
            re.setRenderPipelineState(particlePipeline)
            re.setDepthStencilState(depthRead)
            re.setVertexBuffer(particleBuffer, offset: 0, index: 0)
            re.setVertexBuffer(ub, offset: 0, index: 1)
            re.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: Renderer.particleCapacity)

            // sprite (proiettili, bagliori, onde d'urto)
            if spriteCount > 0 {
                re.setRenderPipelineState(spritePipeline)
                re.setVertexBuffer(spriteBuffers[fi], offset: 0, index: 0)
                re.setVertexBuffer(ub, offset: 0, index: 1)
                re.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: spriteCount)
            }
            re.endEncoding()
        }

        // 3. Bloom
        if let ce = cmd.makeComputeCommandEncoder() {
            ce.setComputePipelineState(brightPSO)
            ce.setTexture(sceneTex, index: 0)
            ce.setTexture(bloomA, index: 1)
            var bp = SIMD4<Float>(1.0, 0.5, 0, 0)
            ce.setBytes(&bp, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            dispatch2D(ce, brightPSO, bloomA.width, bloomA.height)
            ce.endEncoding()
        }
        blurSmall.encode(commandBuffer: cmd, sourceTexture: bloomA, destinationTexture: bloomB)
        if let ce = cmd.makeComputeCommandEncoder() {
            ce.setComputePipelineState(downPSO)
            ce.setTexture(bloomB, index: 0)
            ce.setTexture(bloomC, index: 1)
            dispatch2D(ce, downPSO, bloomC.width, bloomC.height)
            ce.endEncoding()
        }
        blurLarge.encode(commandBuffer: cmd, sourceTexture: bloomC, destinationTexture: bloomD)

        // 4. Composizione + tone mapping
        let cp = MTLRenderPassDescriptor()
        cp.colorAttachments[0].texture = outputTex
        cp.colorAttachments[0].loadAction = .dontCare
        cp.colorAttachments[0].storeAction = .store
        if let re = cmd.makeRenderCommandEncoder(descriptor: cp) {
            re.setRenderPipelineState(compositePipeline)
            re.setFragmentTexture(sceneTex, index: 0)
            re.setFragmentTexture(bloomB, index: 1)
            re.setFragmentTexture(bloomD, index: 2)
            re.setFragmentBuffer(uniformBuffers[fi], offset: 0, index: 0)
            re.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            re.endEncoding()
        }

        // 5. Upscaling MetalFX
        var finalTex: MTLTexture = outputTex
        if let scaler = scaler, let up = upscaledTex {
            scaler.colorTexture = outputTex
            scaler.outputTexture = up
            scaler.inputContentWidth = renderWidth
            scaler.inputContentHeight = renderHeight
            scaler.encode(commandBuffer: cmd)
            finalTex = up
        }

        // 6. Copia sul drawable e presentazione
        if let drawable = view.currentDrawable,
           drawable.texture.width == finalTex.width,
           drawable.texture.height == finalTex.height,
           let blit = cmd.makeBlitCommandEncoder() {
            blit.copy(from: finalTex, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: finalTex.width, height: finalTex.height, depth: 1),
                      to: drawable.texture, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
            cmd.present(drawable)
        }
        cmd.commit()
    }

    private func dispatch1D(_ e: MTLComputeCommandEncoder, _ pso: MTLComputePipelineState, _ count: Int) {
        let w = pso.threadExecutionWidth
        e.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                          threadsPerThreadgroup: MTLSize(width: w, height: 1, depth: 1))
    }

    private func dispatch2D(_ e: MTLComputeCommandEncoder, _ pso: MTLComputePipelineState, _ w: Int, _ h: Int) {
        let tw = pso.threadExecutionWidth
        let th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
        e.dispatchThreads(MTLSize(width: max(1, w), height: max(1, h), depth: 1),
                          threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
    }
}

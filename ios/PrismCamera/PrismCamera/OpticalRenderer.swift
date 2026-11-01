import ARKit
import MetalKit
import simd

// All fields are 16-byte aligned. Keep in sync with Optics.metal and the GPU tests.
struct OpticalUniforms {
    var inverseViewProjection = matrix_identity_float4x4
    var viewProjection = matrix_identity_float4x4
    var worldToCamera = matrix_identity_float4x4
    var model = matrix_identity_float4x4
    var inverseModel = matrix_identity_float4x4
    var inverseProbe = matrix_identity_float4x4
    var imageRow0 = SIMD4<Float>(1, 0, 0, 0)
    var imageRow1 = SIMD4<Float>(0, 1, 0, 0)
    var camera = SIMD4<Float>(0, 0, 0, 1)
    var flags = SIMD4<Float>(repeating: 0)  // placed, depth, probe, wavelength count
    var glass = SIMD4<Float>(1.5046, 0.0042, 1, 0)  // Cauchy A, B (micrometers), scale, lab
    var light = SIMD4<Float>(repeating: 0)  // cinematic reflection axis and blend
    var receiver = SIMD4<Float>(0, 1, 0, 0)
    var viewport = SIMD4<Float>(repeating: 0)
}

// Immutable lifetime holder. No mutable CVPixelBuffer contents cross queues.
private final class GPUFrameResources: @unchecked Sendable {
    let frame: ARFrame
    let textures: [CVMetalTexture]
    init(frame: ARFrame, textures: [CVMetalTexture]) {
        self.frame = frame
        self.textures = textures
    }
}

@MainActor final class OpticalRenderer: NSObject, MTKViewDelegate {
    private let session: ARSession
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let composite: MTLRenderPipelineState
    private let caustics: MTLRenderPipelineState
    private let causticBuilder: MTLComputePipelineState
    private let roomLightBuilder: MTLComputePipelineState
    private var roomLightPool: [MTLBuffer] = []
    private let depthBuilder: MTLComputePipelineState
    private var depthGuide: MTLTexture?
    private var depthTimestamp: TimeInterval = -1
    private var spectrumCache: [Int: MTLBuffer] = [:]
    private var splatPool: [MTLBuffer] = []
    private var submissionIndex = 0
    private var lastFrameTimestamp: TimeInterval = -1
    private var lastUniformData: Data?
    private let finish: MTLRenderPipelineState
    private var cache: CVMetalTextureCache?
    private var target: MTLTexture?
    private var photoTarget: MTLTexture?
    private let emptyOptics: MTLTexture
    private let emptyDepth: MTLTexture
    private let emptyConfidence: MTLTexture
    private let emptyCube: MTLTexture
    private var lockedEnvironment: MTLTexture?
    private var lockedInverseProbe = matrix_identity_float4x4
    private var lightLocked = false
    // Never queue multiple stale camera/gesture states behind a slow frame.
    private let inFlight = DispatchSemaphore(value: 1)
    var lightingRig: LightingRig?
    var studioLight = StudioLightUniforms()
    private var lockedLightsBuilt = false
    var placement: simd_float4x4?
    var placementOverride: simd_float4x4?
    var anchorID: UUID?
    var motionOffset = SIMD3<Float>.zero
    var cinematicStrength: Float = 0
    var cinematicAxis = SIMD3<Float>(0.5, 0.5, 0.7071068)
    var receiverHeight: Float?
    var visiblePlacement: simd_float4x4? {
        guard var transform = placementOverride ?? placement else { return nil }
        transform.columns.3 += SIMD4<Float>(motionOffset, 0)
        return transform
    }
    func basePlacement(fromVisible transform: simd_float4x4) -> simd_float4x4 {
        var base = transform
        base.columns.3 -= SIMD4<Float>(motionOffset, 0)
        return base
    }
    var yaw: Float = 0
    var objectScale: Float = 1
    var roomCaustics = true
    var gpuFailed = false
    var compare = false
    var showDepth = false
    var detail = false
    var captureRequested = false
    var captureDataset = false
    var onCapture: ((Result<URL, Error>) -> Void)?
    var onPerformance: ((String) -> Void)?
    var hasLockedLighting: Bool { lockedEnvironment != nil }
    private var completedFrames = 0
    private var lastReport = CACurrentMediaTime()
    private var gpuMilliseconds: Double = 0
    private var frameTimes: [Double] = []
    private var busyFrames = 0
    private var depthBuilds = 0

    init(view: MTKView, session: ARSession) throws {
        precondition(MemoryLayout<OpticalUniforms>.stride == 512, "Metal uniform layout mismatch")
        precondition(
            MemoryLayout<StudioLightUniforms>.stride == 80, "Lighting uniform layout mismatch")
        guard let device = view.device, let queue = device.makeCommandQueue() else {
            throw NSError(
                domain: "Prism", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Metal is unavailable"])
        }
        // Runtime compilation is supported by Metal and avoids requiring the optional Xcode
        // Metal Toolchain on developer Macs. The bundled source is compiled once per launch.
        let library: MTLLibrary
        if let precompiled = device.makeDefaultLibrary() {
            library = precompiled
        } else {
            guard let url = Bundle.main.url(forResource: "Optics", withExtension: "metal") else {
                throw NSError(
                    domain: "Prism", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Optics.metal is missing"])
            }
            library = try device.makeLibrary(
                source: String(contentsOf: url, encoding: .utf8), options: nil)
        }
        self.session = session
        self.device = device
        self.queue = queue

        func pipeline(
            _ vertex: String, _ fragment: String, format: MTLPixelFormat, additive: Bool = false
        ) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = format
            if additive {
                let attachment = descriptor.colorAttachments[0]!
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .one
                attachment.destinationRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .one
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        composite = try pipeline("fullscreen", "opticalComposite", format: .rgba16Float)
        caustics = try pipeline(
            "causticVertex", "causticFragment", format: .rgba16Float, additive: true)
        causticBuilder = try device.makeComputePipelineState(
            function: library.makeFunction(name: "buildCaustics")!)
        roomLightBuilder = try device.makeComputePipelineState(
            function: library.makeFunction(name: "buildRoomLights")!)
        depthBuilder = try device.makeComputePipelineState(
            function: library.makeFunction(name: "buildDepthGuide")!)
        finish = try pipeline("fullscreen", "opticalFinish", format: .bgra8Unorm)

        func texture(_ format: MTLPixelFormat, bytes: UnsafeRawPointer, bytesPerRow: Int) throws
            -> MTLTexture
        {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: 1, height: 1, mipmapped: false)
            desc.storageMode = .shared
            desc.usage = .shaderRead
            guard let result = device.makeTexture(descriptor: desc) else {
                throw NSError(domain: "Prism", code: 2)
            }
            result.replace(
                region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: bytes,
                bytesPerRow: bytesPerRow)
            return result
        }
        var transparent: UInt32 = 0
        emptyOptics = try texture(.rgba8Unorm, bytes: &transparent, bytesPerRow: 4)
        var far: Float = 100
        emptyDepth = try texture(.r32Float, bytes: &far, bytesPerRow: 4)
        var confidence: UInt8 = 0
        emptyConfidence = try texture(.r8Unorm, bytes: &confidence, bytesPerRow: 1)
        let cubeDesc = MTLTextureDescriptor.textureCubeDescriptor(
            pixelFormat: .rgba8Unorm_srgb, size: 1, mipmapped: false)
        cubeDesc.storageMode = .shared
        cubeDesc.usage = .shaderRead
        guard let cube = device.makeTexture(descriptor: cubeDesc) else {
            throw NSError(domain: "Prism", code: 3)
        }
        var neutral: [UInt8] = [90, 90, 90, 255]
        for face in 0..<6 {
            cube.replace(
                region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, slice: face,
                withBytes: &neutral, bytesPerRow: 4, bytesPerImage: 4)
        }
        emptyCube = cube
        super.init()
        for _ in 0..<1 {
            guard
                let buffer = device.makeBuffer(length: 25 * 384 * 32, options: .storageModePrivate)
            else {
                throw captureError("Could not allocate spectral light buffers.")
            }
            splatPool.append(buffer)
            guard let lights = device.makeBuffer(length: 3 * 32, options: .storageModePrivate)
            else {
                throw captureError("Could not allocate room lighting buffers.")
            }
            roomLightPool.append(lights)
        }
        for count in [13, 31, 25] {
            let values = SpectralTable.samples(count: count)
            guard
                let buffer = device.makeBuffer(
                    bytes: values, length: values.count * 16, options: .storageModeShared)
            else {
                throw captureError("Could not allocate spectral weights.")
            }
            spectrumCache[count] = buffer
        }
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .invalid
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.autoResizeDrawable = false
        view.delegate = self
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { target = nil }

    func setLightLocked(_ enabled: Bool) {
        guard enabled != lightLocked else { return }
        lightLocked = enabled
        lockedLightsBuilt = false
        lastUniformData = nil
        if !enabled { lockedEnvironment = nil }
    }

    private func captureEnvironment(
        _ source: MTLTexture, probe: AREnvironmentProbeAnchor,
        command: MTLCommandBuffer
    ) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.textureCubeDescriptor(
            pixelFormat: source.pixelFormat,
            size: source.width, mipmapped: source.mipmapLevelCount > 1)
        descriptor.storageMode = .private
        descriptor.usage = .shaderRead
        descriptor.mipmapLevelCount = source.mipmapLevelCount
        guard let copy = device.makeTexture(descriptor: descriptor),
            let blit = command.makeBlitCommandEncoder()
        else { return nil }
        copy.label = "Locked practical-light environment"
        blit.label = "Freeze practical-light environment"
        for level in 0..<min(source.mipmapLevelCount, copy.mipmapLevelCount) {
            let width = max(1, source.width >> level)
            let height = max(1, source.height >> level)
            for face in 0..<6 {
                blit.copy(
                    from: source, sourceSlice: face, sourceLevel: level,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: width, height: height, depth: 1),
                    to: copy, destinationSlice: face, destinationLevel: level,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            }
        }
        blit.endEncoding()
        lockedInverseProbe = simd_inverse(probe.transform)
        return copy
    }

    private func opticalBounds(_ model: simd_float4x4, vp: simd_float4x4, width: Int, height: Int)
        -> MTLScissorRect?
    {
        var minimum = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        for x: Float in [-0.09, 0.09] {
            for y: Float in [0, 0.15] {
                for z: Float in [-0.092, 0.092] {
                    let clip = vp * model * SIMD4<Float>(x, y, z, 1)
                    // The volume intersects the near plane: use a conservative full-screen bound.
                    if clip.w < 0.01 {
                        return MTLScissorRect(x: 0, y: 0, width: width, height: height)
                    }
                    let uv = SIMD2<Float>(clip.x / clip.w * 0.5 + 0.5, 0.5 - clip.y / clip.w * 0.5)
                    minimum = simd_min(minimum, uv)
                    maximum = simd_max(maximum, uv)
                }
            }
        }
        let x0 = max(0, min(width, Int(floor(minimum.x * Float(width))) - 2))
        let y0 = max(0, min(height, Int(floor(minimum.y * Float(height))) - 2))
        let x1 = max(0, min(width, Int(ceil(maximum.x * Float(width))) + 2))
        let y1 = max(0, min(height, Int(ceil(maximum.y * Float(height))) + 2))
        guard x1 > x0, y1 > y0 else { return nil }
        return MTLScissorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    private func reportFrame(gpuSeconds: Double) {
        completedFrames += 1
        if gpuSeconds > 0 { frameTimes.append(gpuSeconds * 1000) }
        if gpuSeconds > 0 {
            gpuMilliseconds =
                gpuMilliseconds == 0 ? gpuSeconds * 1000 : gpuMilliseconds * 0.9 + gpuSeconds * 100
        }
        let now = CACurrentMediaTime()
        let elapsed = now - lastReport
        if elapsed >= 1 {
            let gpu =
                gpuMilliseconds > 0
                ? String(format: "%.1f ms GPU", gpuMilliseconds) : "GPU timing unavailable"
            let sorted = frameTimes.sorted()
            let p95 =
                sorted.isEmpty
                ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
            onPerformance?(
                String(
                    format:
                        "%.0f fps · %@ · p95 %.1f ms\n%d busy ticks skipped · %d depth builds · %@",
                    Double(completedFrames) / elapsed, gpu, p95, busyFrames, depthBuilds,
                    String(describing: ProcessInfo.processInfo.thermalState)))
            frameTimes.removeAll(keepingCapacity: true)
            busyFrames = 0
            depthBuilds = 0
            completedFrames = 0
            lastReport = now
        }
    }

    private func mappedTexture(_ buffer: CVPixelBuffer, format: MTLPixelFormat, plane: Int = 0)
        -> CVMetalTexture?
    {
        guard let cache else { return nil }
        let planar = CVPixelBufferIsPlanar(buffer)
        let w = planar ? CVPixelBufferGetWidthOfPlane(buffer, plane) : CVPixelBufferGetWidth(buffer)
        let h =
            planar ? CVPixelBufferGetHeightOfPlane(buffer, plane) : CVPixelBufferGetHeight(buffer)
        var result: CVMetalTexture?
        guard
            CVMetalTextureCacheCreateTextureFromImage(
                nil, cache, buffer, nil, format, w, h, plane, &result) == kCVReturnSuccess
        else { return nil }
        return result
    }

    func draw(in view: MTKView) {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return }
        guard inFlight.wait(timeout: .now()) == .success else {
            busyFrames += 1
            return
        }
        var submitted = false
        defer { if !submitted { inFlight.signal() } }
        let takingPhoto = captureRequested && !captureDataset
        let highQuality = detail || takingPhoto
        let compare = self.compare && !takingPhoto
        let showDepth = self.showDepth && !takingPhoto
        // A bounded render resolution and bounded ray count keep work independent of Retina scale.
        // Present the camera at native display resolution. Limit only the expensive optical layer.
        let pixelScale = view.contentScaleFactor
        let size = CGSize(
            width: floor(view.bounds.width * pixelScale),
            height: floor(view.bounds.height * pixelScale))
        if view.drawableSize != size {
            view.drawableSize = size
            target = nil
        }
        guard let frame = session.currentFrame,
            let luma = mappedTexture(frame.capturedImage, format: .r8Unorm),
            let chroma = mappedTexture(frame.capturedImage, format: .rg8Unorm, plane: 1),
            let yTexture = CVMetalTextureGetTexture(luma),
            let cbcrTexture = CVMetalTextureGetTexture(chroma),
            let drawable = view.currentDrawable, let command = queue.makeCommandBuffer()
        else { return }
        let opticalScale =
            takingPhoto
            ? 1.0
            : min(
                1.0,
                (detail ? 2200.0 : 1600.0)
                    / Double(max(drawable.texture.width, drawable.texture.height)))
        let opticalWidth = max(1, Int(Double(drawable.texture.width) * opticalScale))
        let opticalHeight = max(1, Int(Double(drawable.texture.height) * opticalScale))
        let needsOptics = placement != nil && !compare && !showDepth
        let cachedTarget = takingPhoto ? photoTarget : target
        if needsOptics
            && (cachedTarget?.width != opticalWidth || cachedTarget?.height != opticalHeight)
        {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float,
                width: opticalWidth, height: opticalHeight, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.renderTarget, .shaderRead]
            if takingPhoto {
                photoTarget = device.makeTexture(descriptor: descriptor)
            } else {
                target = device.makeTexture(descriptor: descriptor)
            }
        }
        guard let target = needsOptics ? (takingPhoto ? photoTarget : target) : emptyOptics else {
            if captureRequested {
                captureRequested = false
                onCapture?(
                    .failure(
                        captureError(
                            "Not enough GPU memory for this photo. Retry after closing other apps.")
                    ))
            }
            return
        }
        let depthData = frame.sceneDepth
        let depthRef = depthData.flatMap { mappedTexture($0.depthMap, format: .r32Float) }
        let confidenceRef = depthData?.confidenceMap.flatMap { mappedTexture($0, format: .r8Unorm) }
        let rawDepth = depthRef.flatMap(CVMetalTextureGetTexture) ?? emptyDepth
        let confidence = confidenceRef.flatMap(CVMetalTextureGetTexture) ?? emptyConfidence
        let probe = frame.anchors.compactMap { $0 as? AREnvironmentProbeAnchor }
            .first { $0.environmentTexture?.textureType == .typeCube }
        let needsLightCopy =
            lightLocked && lockedEnvironment == nil && probe?.environmentTexture != nil
        var environment =
            lightLocked
            ? (lockedEnvironment ?? probe?.environmentTexture) : probe?.environmentTexture

        var uniforms = OpticalUniforms()
        let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
        let vp =
            frame.camera.projectionMatrix(
                for: orientation, viewportSize: view.bounds.size, zNear: 0.01, zFar: 20)
            * frame.camera.viewMatrix(for: orientation)
        uniforms.viewProjection = vp
        uniforms.inverseViewProjection = simd_inverse(vp)
        // Sensor depth is measured along the unrotated camera's negative Z axis.
        uniforms.worldToCamera = simd_inverse(frame.camera.transform)
        uniforms.camera = frame.camera.transform.columns.3
        let uv = frame.displayTransform(for: orientation, viewportSize: view.bounds.size).inverted()
        uniforms.imageRow0 = SIMD4<Float>(Float(uv.a), Float(uv.c), Float(uv.tx), 0)
        uniforms.imageRow1 = SIMD4<Float>(Float(uv.b), Float(uv.d), Float(uv.ty), 0)
        if let id = anchorID, let tracked = frame.anchors.first(where: { $0.identifier == id }) {
            placement = tracked.transform
        }
        var local = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0)))
        for column in 0..<3 { local[column] *= objectScale }
        let activePlacement = visiblePlacement
        uniforms.model = (activePlacement ?? matrix_identity_float4x4) * local
        uniforms.inverseModel = simd_inverse(uniforms.model)
        uniforms.flags = SIMD4<Float>(
            placement == nil ? 0 : 1, depthRef == nil || confidenceRef == nil ? 0 : 1,
            environment == nil ? 0 : 1, highQuality ? 31 : 13)
        uniforms.glass = SIMD4<Float>(1.62, 0.012, objectScale, roomCaustics ? 1 : 0)
        // The real receiver stays below the flying object; it never follows its hover.
        uniforms.receiver = receiverHeight.map { SIMD4<Float>(0, 1, 0, -$0) } ?? .zero
        if lightLocked, lockedEnvironment != nil {
            uniforms.inverseProbe = lockedInverseProbe
        } else if let probe {
            uniforms.inverseProbe = simd_inverse(probe.transform)
        }
        uniforms.light = SIMD4<Float>(cinematicAxis, cinematicStrength)  // Optional crystal-only studio reflection treatment.
        uniforms.viewport = SIMD4<Float>(
            Float(target.width), Float(target.height), compare ? 1 : 0, showDepth ? 1 : 0)

        var lighting = studioLight
        var uniformData = withUnsafeBytes(of: uniforms) { Data($0) }
        withUnsafeBytes(of: lighting) { uniformData.append(contentsOf: $0) }
        if !needsLightCopy && !captureRequested && frame.timestamp == lastFrameTimestamp
            && uniformData == lastUniformData
        {
            return
        }
        // Only publish a copied environment after this entire command is committed.
        var pendingEnvironment: MTLTexture?
        if needsLightCopy, let probe, let source = probe.environmentTexture {
            pendingEnvironment = captureEnvironment(source, probe: probe, command: command)
            environment = pendingEnvironment ?? environment
        }
        var depth = rawDepth
        var builtDepth = false
        if uniforms.flags.y > 0.5 && !compare
            && (needsOptics || showDepth
                || (lighting.normalEnabled.w > 0.5 && lighting.sourceGain.w > 0))
        {
            if depthGuide?.width != yTexture.width || depthGuide?.height != yTexture.height {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .rg32Float,
                    width: yTexture.width, height: yTexture.height, mipmapped: false)
                descriptor.storageMode = .private
                descriptor.usage = [.shaderRead, .shaderWrite]
                depthGuide = device.makeTexture(descriptor: descriptor)
                depthTimestamp = -1
            }
            guard let guide = depthGuide else { return }
            if depthTimestamp != frame.timestamp {
                guard let compute = command.makeComputeCommandEncoder() else { return }
                compute.label = "Camera-guided depth reconstruction"
                compute.setComputePipelineState(depthBuilder)
                compute.setTextures([rawDepth, confidence, yTexture, guide], range: 0..<4)
                compute.dispatchThreads(
                    MTLSize(width: guide.width, height: guide.height, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
                compute.endEncoding()
                builtDepth = true
            }
            depth = guide
        }
        let spectrum = spectrumCache[highQuality ? 31 : 13]!
        let causticSpectrum = spectrumCache[25]!

        let roomLights = roomLightPool[submissionIndex % roomLightPool.count]
        var splats: MTLBuffer?
        var fittedLights = false
        if roomCaustics && receiverHeight != nil && environment != nil && placement != nil
            && !compare && !showDepth
        {
            splats = splatPool[submissionIndex % splatPool.count]
            if let splats, let compute = command.makeComputeCommandEncoder() {
                compute.label = "Measured room illumination and spectral transport"
                if !lightLocked || !lockedLightsBuilt {
                    compute.setComputePipelineState(roomLightBuilder)
                    compute.setBytes(
                        &uniforms, length: MemoryLayout<OpticalUniforms>.stride, index: 0)
                    compute.setBuffer(roomLights, offset: 0, index: 1)
                    compute.setTexture(environment ?? emptyCube, index: 0)
                    compute.dispatchThreads(
                        MTLSize(width: 1, height: 1, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
                    compute.memoryBarrier(scope: .buffers)
                    fittedLights = true
                }
                compute.setComputePipelineState(causticBuilder)
                compute.setBytes(&uniforms, length: MemoryLayout<OpticalUniforms>.stride, index: 0)
                compute.setBuffer(splats, offset: 0, index: 1)
                compute.setBuffer(causticSpectrum, offset: 0, index: 2)
                compute.setBuffer(roomLights, offset: 0, index: 3)
                compute.setTextures([depth, confidence], range: 0..<2)
                compute.dispatchThreads(
                    MTLSize(width: 25 * 384, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(
                        width: min(64, causticBuilder.maxTotalThreadsPerThreadgroup), height: 1,
                        depth: 1))
                compute.endEncoding()
            } else {
                splats = nil
            }
        }

        // Light-only and comparison frames never allocate or clear the optical layer.
        if needsOptics {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
            encoder.label = "Camera, spectral glass, and traced caustics"
            encoder.setFragmentBytes(
                &uniforms, length: MemoryLayout<OpticalUniforms>.stride, index: 0)
            encoder.setFragmentTextures(
                [yTexture, cbcrTexture, depth, confidence, environment ?? emptyCube], range: 0..<5)
            encoder.setRenderPipelineState(composite)
            encoder.setFragmentBuffer(spectrum, offset: 0, index: 1)
            if placement != nil && !compare && !showDepth,
                let bounds = opticalBounds(
                    uniforms.model, vp: vp, width: target.width, height: target.height)
            {
                encoder.setScissorRect(bounds)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            if let splats {
                encoder.setScissorRect(
                    MTLScissorRect(x: 0, y: 0, width: target.width, height: target.height))
                encoder.setRenderPipelineState(caustics)
                encoder.setVertexBytes(
                    &uniforms, length: MemoryLayout<OpticalUniforms>.stride, index: 0)
                encoder.setVertexBuffer(splats, offset: 0, index: 1)
                encoder.drawPrimitives(
                    type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 25 * 24 * 16)
            }
            encoder.endEncoding()
        }
        let output = MTLRenderPassDescriptor()
        output.colorAttachments[0].texture = drawable.texture
        output.colorAttachments[0].loadAction = .dontCare
        output.colorAttachments[0].storeAction = .store
        guard let post = command.makeRenderCommandEncoder(descriptor: output) else { return }
        post.setRenderPipelineState(finish)
        post.setFragmentBytes(&uniforms, length: MemoryLayout<OpticalUniforms>.stride, index: 0)
        post.setFragmentBytes(&lighting, length: MemoryLayout<StudioLightUniforms>.stride, index: 2)
        post.setFragmentTexture(target, index: 0)
        post.setFragmentTextures([yTexture, cbcrTexture, depth, confidence], range: 1..<5)
        post.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        post.endEncoding()
        let imageOnly = !captureDataset
        var packet: CapturePacket?
        if captureRequested {
            captureRequested = false
            let w = drawable.texture.width
            let h = drawable.texture.height
            let pitch = ((w * 4 + 255) / 256) * 256
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            if let snapshot = device.makeTexture(descriptor: descriptor),
                let buffer = device.makeBuffer(length: pitch * h, options: .storageModeShared)
            {
                let capturePass = MTLRenderPassDescriptor()
                capturePass.colorAttachments[0].texture = snapshot
                capturePass.colorAttachments[0].loadAction = .dontCare
                capturePass.colorAttachments[0].storeAction = .store
                if let captureEncoder = command.makeRenderCommandEncoder(descriptor: capturePass) {
                    captureEncoder.setRenderPipelineState(finish)
                    captureEncoder.setFragmentBytes(
                        &uniforms, length: MemoryLayout<OpticalUniforms>.stride, index: 0)
                    captureEncoder.setFragmentBytes(
                        &lighting, length: MemoryLayout<StudioLightUniforms>.stride, index: 2)
                    captureEncoder.setFragmentTextures(
                        [target, yTexture, cbcrTexture, depth, confidence], range: 0..<5)
                    captureEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    captureEncoder.endEncoding()
                    if let blit = command.makeBlitCommandEncoder() {
                        blit.copy(
                            from: snapshot, sourceSlice: 0, sourceLevel: 0,
                            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                            sourceSize: MTLSize(width: w, height: h, depth: 1), to: buffer,
                            destinationOffset: 0,
                            destinationBytesPerRow: pitch, destinationBytesPerImage: pitch * h)
                        blit.endEncoding()
                        packet = CapturePacket(
                            frame: frame, uniforms: uniforms, width: w, height: h, buffer: buffer,
                            bytesPerRow: pitch, viewport: view.bounds.size,
                            orientation: orientation,
                            lightingLocked: lightLocked
                                && (lockedEnvironment != nil || pendingEnvironment != nil),
                            studioLight: lighting)
                    }
                }
            }
            if packet == nil {
                DispatchQueue.main.async { [weak self] in
                    self?.onCapture?(
                        .failure(
                            captureError(
                                "Not enough resources for capture. Turn Detail off and retry.")))
                }
            }
        }
        command.present(drawable)
        // CVMetalTexture wrappers and the frame must survive asynchronous GPU reads.
        let resources = GPUFrameResources(
            frame: frame, textures: [luma, chroma] + [depthRef, confidenceRef].compactMap { $0 })
        let semaphore = inFlight
        command.addCompletedHandler { [weak self, resources, packet] buffer in
            withExtendedLifetime(resources) {}
            if buffer.status == .error {
                Task { @MainActor [weak self] in
                    self?.gpuFailed = true
                    self?.depthTimestamp = -1
                    self?.lockedLightsBuilt = false
                    self?.lockedEnvironment = nil
                    self?.lastUniformData = nil
                    if packet != nil {
                        self?.onCapture?(
                            .failure(captureError("The GPU could not finish the capture.")))
                    }
                    semaphore.signal()
                }
            } else {
                let seconds = buffer.gpuEndTime - buffer.gpuStartTime
                Task { @MainActor [weak self] in
                    self?.gpuFailed = false
                    self?.reportFrame(gpuSeconds: seconds)
                    semaphore.signal()
                }
                if let packet {
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        let result = Result { try packet.write(imageOnly: imageOnly) }
                        Task { @MainActor [weak self] in self?.onCapture?(result) }
                    }
                }
            }
        }
        lastFrameTimestamp = frame.timestamp
        lastUniformData = uniformData
        submissionIndex += 1
        submitted = true
        command.commit()
        if let pendingEnvironment { lockedEnvironment = pendingEnvironment }
        if builtDepth {
            depthTimestamp = frame.timestamp
            depthBuilds += 1
        }
        if fittedLights && lightLocked && lockedEnvironment != nil { lockedLightsBuilt = true }
    }
}

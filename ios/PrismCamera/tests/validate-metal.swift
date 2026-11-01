import Foundation
import Metal
import simd

// This uses macOS's runtime Metal compiler, not the optional Xcode Metal Toolchain.
// Run from a normal Mac terminal before device installation.
guard let device = MTLCreateSystemDefaultDevice() else {
    print("SKIP: no Metal device available. Shader/GPU validation was not performed.")
    exit(0)
}
guard CommandLine.arguments.count == 2 else {
    print("Usage: validate-metal /path/to/Optics.metal")
    exit(2)
}
func require(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: \(message)"); exit(1) }
}
let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
let library = try device.makeLibrary(source: source, options: nil)
for (vertex, fragment, format) in [
    ("fullscreen", "opticalComposite", MTLPixelFormat.rgba16Float),
    ("causticVertex", "causticFragment", .rgba16Float),
    ("fullscreen", "opticalFinish", .bgra8Unorm)
] {
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: vertex)
    descriptor.fragmentFunction = library.makeFunction(name: fragment)
    descriptor.colorAttachments[0].pixelFormat = format
    if vertex == "causticVertex" {
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .one
    }
    _ = try device.makeRenderPipelineState(descriptor: descriptor)
}
_ = try device.makeComputePipelineState(function: library.makeFunction(name: "buildCaustics")!)
_ = try device.makeComputePipelineState(function: library.makeFunction(name: "buildDepthGuide")!)
_ = try device.makeComputePipelineState(function: library.makeFunction(name: "buildRoomLights")!)
struct Ray { var origin: SIMD4<Float>; var direction: SIMD4<Float>; var glass: SIMD4<Float> }
struct Result { var exitPoint: SIMD4<Float>; var outgoing: SIMD4<Float>; var metrics: SIMD4<Float> }
let rays = [
    Ray(origin: SIMD4<Float>(0,0.06,0.5,1), direction: SIMD4<Float>(0,0,-1,0), glass: SIMD4<Float>(550,1.5,0,0)),
    Ray(origin: SIMD4<Float>(0.3,0.3,1,1), direction: SIMD4<Float>(0,0,-1,0), glass: SIMD4<Float>(550,1.5,0,0))
]
let input = device.makeBuffer(bytes: rays, length: MemoryLayout<Ray>.stride * rays.count, options: .storageModeShared)!
let output = device.makeBuffer(length: MemoryLayout<Result>.stride * rays.count, options: .storageModeShared)!
let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "testTransport")!)
let queue = device.makeCommandQueue()!
let command = queue.makeCommandBuffer()!
let encoder = command.makeComputeCommandEncoder()!
encoder.setComputePipelineState(pipeline)
encoder.setBuffer(input, offset: 0, index: 0)
encoder.setBuffer(output, offset: 0, index: 1)
encoder.dispatchThreads(MTLSize(width: rays.count, height: 1, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: rays.count, height: 1, depth: 1))
encoder.endEncoding()
command.commit()
command.waitUntilCompleted()
require(command.status == .completed, "GPU command failed: \(String(describing: command.error))")
let result = output.contents().bindMemory(to: Result.self, capacity: rays.count)
require(result[0].exitPoint.w == 1, "normal ray must exit")
require(result[0].metrics.x > 0.1 && result[0].metrics.x < 0.3, "GPU crystal path outside closed bounds")
let outgoing = SIMD3<Float>(result[0].outgoing.x, result[0].outgoing.y, result[0].outgoing.z)
require(abs(length(outgoing) - 1) < 0.0002, "GPU crystal direction must be normalized")
require(result[0].outgoing.w > 0 && result[0].outgoing.w <= 1, "GPU crystal energy outside bounds")
require(result[1].exitPoint.w == 0, "missing ray must not transmit")
print("PASS: Metal source, three render pipelines, and GPU transport on \(device.name)")

// Exercise the actual compute-to-raster data layout, not just pipeline creation.
var uniforms = [Float](repeating: 0, count: 128)
for matrix in 0..<6 { for diagonal in 0..<4 { uniforms[matrix*16+diagonal*5] = 1 } }
uniforms[96] = 1; uniforms[101] = 1 // sensor UV rows
uniforms[107] = 1 // camera w
uniforms[108] = 1; uniforms[111] = 13 // placement and spectrum
uniforms[112] = 1.5046; uniforms[113] = 0.0042; uniforms[114] = 1; uniforms[115] = 1
uniforms[116] = 0.99; uniforms[117] = 0.10; uniforms[118] = 0.04; uniforms[119] = 1
uniforms[121] = 1; uniforms[124] = 720; uniforms[125] = 1280
let causticFunction = try device.makeComputePipelineState(function: library.makeFunction(name: "buildCaustics")!)
let count = 25*384
let splats = device.makeBuffer(length: count*32, options: .storageModeShared)!
func emptyTexture(_ format: MTLPixelFormat) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 1, height: 1, mipmapped: false)
    d.storageMode = .shared
    let t = device.makeTexture(descriptor: d)!
    var zero = [UInt8](repeating: 0, count: 16)
    t.replace(region: MTLRegionMake2D(0,0,1,1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 16)
    return t
}
var spectral = [SIMD4<Float>](), normalization = SIMD3<Float>(repeating: 0)
for i in 0..<25 {
    let nm = Float(420)+260*Float(i)/24
    let x = (SIMD3<Float>(repeating: nm)-SIMD3<Float>(610,545,455))/SIMD3<Float>(39,32,25)
    let w = SIMD3<Float>(exp(-0.5*x.x*x.x),exp(-0.5*x.y*x.y),exp(-0.5*x.z*x.z))
    normalization += w
    spectral.append(SIMD4<Float>(w,1.5046+0.0042/pow(nm*0.001,2)))
}
for i in spectral.indices {
    for j in 0..<3 { spectral[i][j] /= normalization[j] }
}
let spectrumBuffer = device.makeBuffer(bytes: spectral,length: spectral.count*16,options: .storageModeShared)!
let depthTexture = emptyTexture(.r32Float), confidenceTexture = emptyTexture(.r8Unorm)
let roomLightBuffer = device.makeBuffer(length: 3*32, options: .storageModeShared)!
for power: Float in [1, 0] {
    var room = [SIMD4<Float>](repeating: .zero,count: 6)
    // Controlled source exists only in this transport test, never as an app fallback.
    room[0] = SIMD4<Float>(normalize(SIMD3<Float>(0.99,0.1,0.04)),0)
    room[1] = SIMD4<Float>(power,power,power,1)
    room.withUnsafeBytes { roomLightBuffer.contents().copyMemory(from: $0.baseAddress!,byteCount: $0.count) }
    uniforms[119] = power
    let c = queue.makeCommandBuffer()!, e = c.makeComputeCommandEncoder()!
    e.setComputePipelineState(causticFunction)
    e.setBytes(&uniforms, length: 512, index: 0)
    e.setBuffer(splats, offset: 0, index: 1)
    e.setBuffer(spectrumBuffer, offset: 0, index: 2)
    e.setBuffer(roomLightBuffer, offset: 0, index: 3)
    e.setTextures([depthTexture,confidenceTexture], range: 0..<2)
    e.dispatchThreads(MTLSize(width: count,height: 1,depth: 1),
        threadsPerThreadgroup: MTLSize(width: min(64,causticFunction.maxTotalThreadsPerThreadgroup),height: 1,depth: 1))
    e.endEncoding(); c.commit(); c.waitUntilCompleted()
    require(c.status == .completed,"caustic compute failed")
    let values = splats.contents().bindMemory(to: Float.self, capacity: count*8)
    var live = 0
    for i in 0..<count {
        for j in 0..<8 { require(values[i*8+j].isFinite,"nonfinite caustic data") }
        if values[i*8+7]>0.5 {
            live += 1
            require(values[i*8+3]>0,"positive caustic footprint")
            for j in 4...6 {
                require(values[i*8+j]>=0,"nonnegative spectral power")
                if power == 0 { require(values[i*8+j]==0,"disabled light must have zero energy") }
            }
        }
    }
    require(live>0,"default aperture must illuminate the receiver")
}
print("PASS: caustic compute buffers, finite receiver hits and zero-light energy")

// Guided-depth regression: invalid samples must never become geometry; a constant plane stays constant.
let guidePipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "buildDepthGuide")!)
let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg32Float,width: 8,height: 8,mipmapped: false)
descriptor.storageMode = .shared; descriptor.usage = [.shaderRead,.shaderWrite]
let guide = device.makeTexture(descriptor: descriptor)!
let lumaTexture = emptyTexture(.r8Unorm)
for reliable: UInt8 in [2,0] {
    var z: Float = 1.5, confidenceValue = reliable
    depthTexture.replace(region: MTLRegionMake2D(0,0,1,1),mipmapLevel: 0,withBytes: &z,bytesPerRow: 4)
    confidenceTexture.replace(region: MTLRegionMake2D(0,0,1,1),mipmapLevel: 0,withBytes: &confidenceValue,bytesPerRow: 1)
    let c = queue.makeCommandBuffer()!, e = c.makeComputeCommandEncoder()!
    e.setComputePipelineState(guidePipeline)
    e.setTextures([depthTexture,confidenceTexture,lumaTexture,guide],range: 0..<4)
    e.dispatchThreads(MTLSize(width: 8,height: 8,depth: 1),threadsPerThreadgroup: MTLSize(width: 8,height: 8,depth: 1))
    e.endEncoding(); c.commit(); c.waitUntilCompleted()
    require(c.status == .completed,"guided depth compute failed")
    var values = [Float](repeating: 0,count: 128)
    guide.getBytes(&values,bytesPerRow: 8*8,from: MTLRegionMake2D(0,0,8,8),mipmapLevel: 0)
    for pixel in 0..<64 {
        let inverse = values[pixel*2], weight = values[pixel*2+1]
        require(inverse.isFinite && weight.isFinite,"guided depth must be finite")
        if reliable == 0 { require(weight == 0,"invalid depth cannot fabricate a receiver") }
        else { require(abs(weight/inverse-1.5)<0.001,"depth reconstruction must preserve a flat plane") }
    }
}
print("PASS: depth guide preserves planes and rejects missing confidence")

// A uniform captured environment must not be turned into an invented directional lamp.
let roomPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "buildRoomLights")!)
let cubeDescriptor = MTLTextureDescriptor.textureCubeDescriptor(pixelFormat: .rgba8Unorm,size: 1,mipmapped: false)
cubeDescriptor.storageMode = .shared
let roomCube = device.makeTexture(descriptor: cubeDescriptor)!
for face in 0..<6 {
    var color: [UInt8] = [51,51,51,255]
    roomCube.replace(region: MTLRegionMake2D(0,0,1,1),mipmapLevel: 0,slice: face,
                     withBytes: &color,bytesPerRow: 4,bytesPerImage: 4)
}
for hasProbe: Float in [0,1] {
    uniforms[110] = hasProbe
    let c = queue.makeCommandBuffer()!, e = c.makeComputeCommandEncoder()!
    e.setComputePipelineState(roomPipeline)
    e.setBytes(&uniforms,length: 512,index: 0)
    e.setBuffer(roomLightBuffer,offset: 0,index: 1)
    e.setTexture(roomCube,index: 0)
    e.dispatchThreads(MTLSize(width: 1,height: 1,depth: 1),threadsPerThreadgroup: MTLSize(width: 1,height: 1,depth: 1))
    e.endEncoding(); c.commit(); c.waitUntilCompleted()
    require(c.status == .completed,"room-light fitting failed")
    let values = roomLightBuffer.contents().bindMemory(to: Float.self,capacity: 24)
    for i in 0..<3 { require(values[i*8+7]==0,"uniform or missing environment must not create a directional source") }
}
print("PASS: uniform/missing environment does not create a synthetic sun")

var bright: [UInt8] = [255,255,255,255]
roomCube.replace(region: MTLRegionMake2D(0,0,1,1),mipmapLevel: 0,slice: 2,
                 withBytes: &bright,bytesPerRow: 4,bytesPerImage: 4)
uniforms[110] = 1
let roomCommand = queue.makeCommandBuffer()!, roomEncoder = roomCommand.makeComputeCommandEncoder()!
roomEncoder.setComputePipelineState(roomPipeline)
roomEncoder.setBytes(&uniforms,length: 512,index: 0)
roomEncoder.setBuffer(roomLightBuffer,offset: 0,index: 1)
roomEncoder.setTexture(roomCube,index: 0)
roomEncoder.dispatchThreads(MTLSize(width: 1,height: 1,depth: 1),threadsPerThreadgroup: MTLSize(width: 1,height: 1,depth: 1))
roomEncoder.endEncoding(); roomCommand.commit(); roomCommand.waitUntilCompleted()
require(roomCommand.status == .completed,"bright room fitting failed")
let fitted = roomLightBuffer.contents().bindMemory(to: Float.self,capacity: 24)
require(fitted[7]>0 && fitted[1]<0 && fitted[4]>0,"bright upper environment must emit downward positive radiance")
print("PASS: captured bright region drives incoming light direction and energy")

// Full production finish pass: diffuse plane, zero power, no depth, compare, and feather.
let finishDescriptor = MTLRenderPipelineDescriptor()
finishDescriptor.vertexFunction = library.makeFunction(name: "fullscreen")
finishDescriptor.fragmentFunction = library.makeFunction(name: "opticalFinish")
finishDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
let finishPipeline = try device.makeRenderPipelineState(descriptor: finishDescriptor)
let outDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,width: 32,height: 32,mipmapped: false)
outDescriptor.storageMode = .shared; outDescriptor.usage = [.renderTarget]
let fillOutput = device.makeTexture(descriptor: outDescriptor)!
let fillDepth = emptyTexture(.rg32Float)
var flat: [Float] = [1/1.5,1]
fillDepth.replace(region: MTLRegionMake2D(0,0,1,1),mipmapLevel: 0,withBytes: &flat,bytesPerRow: 8)
let gray = emptyTexture(.r8Unorm), chroma = emptyTexture(.rg8Unorm), optical = emptyTexture(.rgba8Unorm)
var grayValue: UInt8 = 100
var neutralChroma: [UInt8] = [128,128]
gray.replace(region: MTLRegionMake2D(0,0,1,1),mipmapLevel: 0,withBytes: &grayValue,bytesPerRow: 1)
chroma.replace(region: MTLRegionMake2D(0,0,1,1),mipmapLevel: 0,withBytes: &neutralChroma,bytesPerRow: 2)
var projection = matrix_identity_float4x4
projection[2] = SIMD4<Float>(0,0,-20/19.99,-1)
projection[3] = SIMD4<Float>(0,0,-0.2/19.99,0)
let inverseProjection = simd_inverse(projection)
uniforms = [Float](repeating: 0,count: 128)
for matrix in 0..<6 { for diagonal in 0..<4 { uniforms[matrix*16+diagonal*5] = 1 } }
for column in 0..<4 { for row in 0..<4 {
    uniforms[column*4+row] = inverseProjection[column][row]
    uniforms[16+column*4+row] = projection[column][row]
} }
uniforms[96] = 1; uniforms[101] = 1; uniforms[107] = 1
uniforms[109] = 1; uniforms[124] = 32; uniforms[125] = 32
func renderFill(gain: Float, hasDepth: Bool = true, compare: Bool = false, style: Float = 0) -> [UInt8] {
    uniforms[109] = hasDepth ? 1 : 0; uniforms[126] = compare ? 1 : 0
    var light: [SIMD4<Float>] = [SIMD4<Float>(0,0,0,gain),SIMD4<Float>(0,0,-1.5,0.5),
                                SIMD4<Float>(1,1,1,0.7),SIMD4<Float>(0,1,0,1),SIMD4<Float>(1,0,0,style)]
    let c = queue.makeCommandBuffer()!, pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = fillOutput
    pass.colorAttachments[0].loadAction = .dontCare; pass.colorAttachments[0].storeAction = .store
    let e = c.makeRenderCommandEncoder(descriptor: pass)!
    e.setRenderPipelineState(finishPipeline)
    e.setFragmentBytes(&uniforms,length: 512,index: 0)
    e.setFragmentBytes(&light,length: 80,index: 2)
    e.setFragmentTextures([optical,gray,chroma,fillDepth,confidenceTexture],range: 0..<5)
    e.drawPrimitives(type: .triangle,vertexStart: 0,vertexCount: 3)
    e.endEncoding(); c.commit(); c.waitUntilCompleted()
    require(c.status == .completed,"surface-fill render failed")
    var bytes = [UInt8](repeating: 0,count: 32*32*4)
    fillOutput.getBytes(&bytes,bytesPerRow: 32*4,from: MTLRegionMake2D(0,0,32,32),mipmapLevel: 0)
    return bytes
}
let baseline = renderFill(gain: 0)
let filled = renderFill(gain: 1)
require(renderFill(gain: 1,hasDepth: false) == baseline,"missing depth must preserve original image")
require(renderFill(gain: 1,compare: true) == baseline,"compare must bypass lighting")
let center = (16*32+16)*4
require(filled[center+1]>baseline[center+1]+5,"front-facing matte plane must receive fill")
require(filled[0] == baseline[0],"pixels outside the footprint remain unchanged")
for p in 0..<32*32 { require(filled[p*4+3] == 255,"surface fill cannot corrupt image alpha") }
print("PASS: production surface fill, zero power, missing depth, compare, bounded footprint and alpha")

var renderedStyles = Set<Data>()
for style: Float in [0,1,2,3,4] {
    let pixels = renderFill(gain: 1, style: style)
    require(pixels != baseline,"each lighting modifier illuminates the measured plane")
    require(renderFill(gain: 0, style: style)==baseline,"all modifiers preserve zero power")
    require(renderFill(gain: 1, hasDepth: false, style: style)==baseline,"all modifiers require depth")
    renderedStyles.insert(Data(pixels))
}
require(renderedStyles.count==5,"lighting modifiers must produce distinct images")
print("PASS: five distinct GPU light modifiers and zero/missing-depth safeguards")

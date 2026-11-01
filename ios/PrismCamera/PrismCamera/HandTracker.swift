import ARKit
import Vision

struct HandSample {
    let frame: ARFrame
    let sensorPoint: CGPoint
    let pinchRatio: Float
    let palmWorldPosition: SIMD3<Float>?
}

// One request at a time; stale work is dropped rather than queued behind the renderer.
@MainActor final class HandTracker {
    private let queue = DispatchQueue(label: "Spectral.hand-pose", qos: .userInitiated)
    private var busy = false
    private var lastSubmission: TimeInterval = 0
    private var generation = 0
    private let detector = HandDetector()
    var onSample: ((HandSample?) -> Void)?

    func cancel() { generation += 1 }

    func submit(_ frame: ARFrame, orientation: CGImagePropertyOrientation, active: Bool) {
        guard !busy, frame.timestamp-lastSubmission >= (active ? 1.0/12.0 : 1.0/4.0) else { return }
        busy = true
        lastSubmission = frame.timestamp
        let token = generation
        let detector = self.detector
        queue.async { [weak self] in
            let result = detector.detect(frame, orientation: orientation)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.busy = false
                guard token == self.generation else { return }
                self.onSample?(result)
            }
        }
    }

}

// Exclusively used on HandTracker.queue; keep Vision resources warm between frames.
private final class HandDetector: @unchecked Sendable {
    private let request = VNDetectHumanHandPoseRequest()
    private func palmPosition(_ frame: ARFrame, uv: SIMD2<Float>, palmPixels: Float) -> SIMD3<Float>? {
        guard uv.x>0, uv.x<1, uv.y>0, uv.y<1,
              let data=frame.sceneDepth, let confidence=data.confidenceMap else { return nil }
        let map=data.depthMap, width=CVPixelBufferGetWidth(map), height=CVPixelBufferGetHeight(map)
        CVPixelBufferLockBaseAddress(map,.readOnly)
        CVPixelBufferLockBaseAddress(confidence,.readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map,.readOnly); CVPixelBufferUnlockBaseAddress(confidence,.readOnly) }
        guard let base=CVPixelBufferGetBaseAddress(map), let conf=CVPixelBufferGetBaseAddress(confidence) else { return nil }
        let x=Int(uv.x*Float(width)), y=Int(uv.y*Float(height))
        guard x>0, x<width-1, y>0, y<height-1 else { return nil }
        var values=[Float](); values.reserveCapacity(9)
        for j in -1...1 { for i in -1...1 {
            let c=conf.advanced(by:(y+j)*CVPixelBufferGetBytesPerRow(confidence)).assumingMemoryBound(to:UInt8.self)[x+i]
            if c>=1 { values.append(base.advanced(by:(y+j)*CVPixelBufferGetBytesPerRow(map)).assumingMemoryBound(to:Float.self)[x+i]) }
        } }
        guard let z=InteractionMath.reliableHandDepth(values) else { return nil }
        let k=frame.camera.intrinsics, size=frame.camera.imageResolution
        let palmMeters=palmPixels*z/k[0][0]
        guard palmMeters>0.025, palmMeters<0.14 else { return nil }
        let local=SIMD4<Float>((uv.x*Float(size.width)-k[2][0])/k[0][0]*z,
            -(uv.y*Float(size.height)-k[2][1])/k[1][1]*z,-z,1)
        let world=frame.camera.transform*local
        return SIMD3<Float>(world.x,world.y,world.z)
    }

    func detect(_ frame: ARFrame, orientation: CGImagePropertyOrientation) -> HandSample? {
        request.maximumHandCount = 1
        do {
            try VNImageRequestHandler(cvPixelBuffer: frame.capturedImage, orientation: orientation).perform([request])
            guard let hand = request.results?.first else { return nil }
            let points = try hand.recognizedPoints(.all)
            guard let thumb = points[.thumbTip], let index = points[.indexTip],
                  let wrist = points[.wrist], let knuckle = points[.middleMCP] ?? points[.indexMCP],
                  thumb.confidence >= 0.35, index.confidence >= 0.35,
                  wrist.confidence >= 0.25, knuckle.confidence >= 0.25 else { return nil }
            func sensor(_ p: CGPoint) -> SIMD2<Float> {
                InteractionMath.sensorPoint(vision: SIMD2<Float>(Float(p.x),Float(p.y)), orientation: Int(orientation.rawValue))
            }
            let t = sensor(thumb.location), i = sensor(index.location)
            let w = sensor(wrist.location), k = sensor(knuckle.location)
            let dimensions = SIMD2<Float>(Float(frame.camera.imageResolution.width),Float(frame.camera.imageResolution.height))
            let palm = simd_length((k-w)*dimensions)
            guard palm>20 else { return nil }
            let center = (t+i)*0.5
            return HandSample(frame: frame, sensorPoint: CGPoint(x: CGFloat(center.x), y: CGFloat(center.y)),
                              pinchRatio: simd_length((t-i)*dimensions)/palm,
                              palmWorldPosition: palmPosition(frame, uv: (w+k)*0.5, palmPixels: palm))
        } catch { return nil }
    }
}

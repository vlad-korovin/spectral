import Foundation
import simd

// Separate 80-byte block; the established spectral/capture uniform ABI stays intact.
struct StudioLightUniforms {
    var sourceGain = SIMD4<Float>(repeating: 0)
    var targetRadius = SIMD4<Float>(0, 0, 0, 0.25)
    var colorSoftness = SIMD4<Float>(1, 1, 1, 0.7)
    var normalEnabled = SIMD4<Float>(0, 1, 0, 0)
    var shapeRight = SIMD4<Float>(1, 0, 0, 0) // orthogonal profile axis; w = LightingStyle ID
}

// Raw values are shared with Metal and recorded in capture metadata.
enum LightingStyle: Int, CaseIterable, Identifiable {
    case soft = 0, spot, strip, window, halo
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .soft: return "Soft"
        case .spot: return "Spot"
        case .strip: return "Strip"
        case .window: return "Window"
        case .halo: return "Halo"
        }
    }
    var hint: String {
        switch self {
        case .soft: return "A gentle pool for matte subjects"
        case .spot: return "A focused beam with a feathered edge"
        case .strip: return "A slender wash for sculpting form"
        case .window: return "Four soft panes across your backdrop"
        case .halo: return "A luminous ring for a measured backdrop"
        }
    }
}

enum CrystalPlacement: String, CaseIterable, Identifiable {
    case surface = "Surface", space = "Space"
    var id: Self { self }
}

// A bounded pose relative to an AR anchor, never incremental vertical translation.
// Pausing retains the visible pose; restarting blends from it instead of accumulating lift.
struct IdleCrystalMotion {
    private var lastTime: TimeInterval?
    private var idleSince: TimeInterval = 0
    private var startOffset = SIMD3<Float>.zero
    private var startCinema: Float = 0
    private var landingSince: TimeInterval?
    private(set) var offset = SIMD3<Float>.zero
    private(set) var cinema: Float = 0
    var isLanding: Bool { landingSince != nil }

    mutating func reset(at time: TimeInterval) {
        lastTime = time; idleSince = time
        startOffset = offset; startCinema = cinema
    }
    mutating func pause(at time: TimeInterval) { landingSince = nil; reset(at: time) }
    mutating func clear(at time: TimeInterval) {
        offset = .zero; cinema = 0; landingSince = nil; reset(at: time)
    }
    mutating func land(at time: TimeInterval) {
        reset(at: time); landingSince = time
    }
    private func ease(_ t: Double) -> Float {
        let x = Float(min(1,max(0,t)))
        return x*x*x*(x*(x*6-15)+10)
    }
    mutating func step(at time: TimeInterval, enabled: Bool) -> Float {
        guard time.isFinite else { lastTime = nil; return 0 }
        guard let previous = lastTime, time >= previous, time-previous <= 0.25 else {
            // Interrupted landings also resume from the current pose without a time jump.
            if landingSince != nil { landingSince = time }
            reset(at: time); return 0
        }
        if let landing = landingSince {
            let blend = ease((time-landing)/1.2)
            offset = startOffset*(1-blend); cinema = startCinema*(1-blend)
            lastTime = time
            if blend>=1 { landingSince = nil; reset(at: time) }
            return 0
        }
        guard enabled else { reset(at: time); return 0 }
        lastTime = time
        let t = max(0,time-idleSince-3)
        let blend = ease(t/3.5)
        let hover = SIMD3<Float>(0.008*Float(sin(t*0.55)),
            0.12+0.012*Float(sin(t*0.85)), 0.006*Float(cos(t*0.5)-1))
        offset = startOffset+(hover-startOffset)*blend
        cinema = startCinema+(1-startCinema)*blend
        func angle(_ timestamp: TimeInterval) -> Double {
            let phase = max(0,timestamp-idleSince-3)
            return 0.075*(phase-3*(1-exp(-phase/3)))
        }
        return Float(angle(time)-angle(previous))
    }
}

struct LightingRig {
    var target: SIMD3<Float>
    var right: SIMD3<Float>
    var towardCamera: SIMD3<Float>

    func uniforms(radius: Float, stops: Float, angle: Float, warmth: Float, style: LightingStyle = .soft) -> StudioLightUniforms {
        var result = StudioLightUniforms()
        let offset = right * sin(angle) + towardCamera * cos(angle)
        result.sourceGain = SIMD4<Float>(target + offset * 0.7 + SIMD3<Float>(0, 0.35, 0),
                                         exp2(min(1.5, max(0, stops))) - 1)
        result.targetRadius = SIMD4<Float>(target, min(0.8, max(0.06, radius)))
        // Artistic tint, explicitly not a calibrated correlated colour temperature.
        let t = min(1, max(-1, warmth))
        result.colorSoftness = SIMD4<Float>(1 - max(-t, 0)*0.35, 1 - abs(t)*0.12,
                                            1 - max(t, 0)*0.45, 0.7)
        let source = SIMD3<Float>(result.sourceGain.x, result.sourceGain.y, result.sourceGain.z)
        let axis = simd_normalize(target-source)
        var horizontal = right-axis*simd_dot(right,axis)
        if simd_length_squared(horizontal) < 0.0001 {
            let fallback = abs(axis.y)<0.9 ? SIMD3<Float>(0,1,0) : SIMD3<Float>(1,0,0)
            horizontal = simd_cross(axis,fallback)
        }
        result.shapeRight = SIMD4<Float>(simd_normalize(horizontal), Float(style.rawValue))
        result.normalEnabled.w = 1
        return result
    }
}

// Explicit ownership guard: an old Vision result can never reclaim a touched object.
struct InteractionOwnership {
    private var lastTouch: TimeInterval = -.infinity
    private var resumeHandsAt: TimeInterval = -.infinity
    mutating func touch(at time: TimeInterval) {
        lastTouch = time; resumeHandsAt = time+0.4
    }
    func allowsHands(now: TimeInterval, sampleTime: TimeInterval) -> Bool {
        now>=resumeHandsAt && sampleTime>lastTouch && now>=sampleTime && now-sampleTime<0.3
    }
}

struct CrystalHandGrab {
    var position: SIMD3<Float>
    var grip: SIMD3<Float>
    var normal: SIMD3<Float>
    var usesDepth: Bool
    var sampleTime: TimeInterval
    func target(for point: SIMD3<Float>) -> SIMD3<Float> { position+(point-grip) }
}

enum InteractionMath {
    static func reliableHandDepth(_ samples: [Float]) -> Float? {
        let valid = samples.filter { $0.isFinite && $0>=0.15 && $0<=1.4 }.sorted()
        guard valid.count>=5 else { return nil }
        let median = valid[valid.count/2]
        // Reject patches straddling foreground/background; never pick a new layer mid-grab.
        guard valid.last!-valid.first! <= max(0.025,median*0.04) else { return nil }
        return median
    }
    static func handSmoothing(dt: TimeInterval) -> Float {
        1-exp(-Float(max(0,min(0.15,dt)))/0.055)
    }

    // Vision coordinates are bottom-left in the EXIF-oriented image; ARKit uses native top-left UV.
    static func sensorPoint(vision p: SIMD2<Float>, orientation: Int) -> SIMD2<Float> {
        switch orientation {
        case 6: return SIMD2<Float>(1-p.y,1-p.x) // right
        case 8: return SIMD2<Float>(p.y,p.x) // left
        case 3: return SIMD2<Float>(1-p.x,p.y) // down
        default: return SIMD2<Float>(p.x,1-p.y) // up
        }
    }

    static func planeHit(origin: SIMD3<Float>, direction: SIMD3<Float>, height: Float) -> SIMD3<Float>? {
        guard abs(direction.y) > 0.025 else { return nil }
        let t = (height - origin.y) / direction.y
        guard t > 0, t < 8 else { return nil }
        return origin + t * direction
    }

    // Fixed world-space drag plane: camera motion during a drag cannot change its depth.
    static func dragPlaneHit(origin: SIMD3<Float>, direction: SIMD3<Float>,
                             point: SIMD3<Float>, normal: SIMD3<Float>) -> SIMD3<Float>? {
        let denominator = simd_dot(direction,normal)
        guard abs(denominator)>0.025 else { return nil }
        let t = simd_dot(point-origin,normal)/denominator
        guard t>0, t<8, t.isFinite else { return nil }
        return origin+direction*t
    }

    static func dragTranslation(startPosition: SIMD3<Float>, startHit: SIMD3<Float>,
                                currentHit: SIMD3<Float>) -> SIMD3<Float> {
        let delta = currentHit - startHit
        return startPosition + SIMD3<Float>(delta.x, 0, delta.z)
    }

    // Both values are derived from the recognizer's begin state. This avoids
    // accumulating frame-sized deltas, so touch event rate cannot change the result.
    static func gestureScale(start: Float, magnification: Float) -> Float {
        min(2.2, max(0.4, start * magnification))
    }

    static func gestureYaw(start: Float, rotation: Float) -> Float {
        let twoPi = 2 * Float.pi
        var value = (start - rotation).truncatingRemainder(dividingBy: twoPi)
        if value > .pi { value -= twoPi }
        if value < -.pi { value += twoPi }
        return value
    }

    static func mayRecognizeTogether(_ first: String, _ second: String) -> Bool {
        // Pan yields its position at transform begin; it must not prevent that begin.
        let manipulation = ["pan", "pinch", "rotation"]
        return first != second && manipulation.contains(first) && manipulation.contains(second)
    }

    // An expanded interaction box provides a comfortable touch target around the optical solid.
    static func touchesGlass(origin: SIMD3<Float>, direction: SIMD3<Float>, model: simd_float4x4) -> Bool {
        let inverse = simd_inverse(model)
        let o4 = inverse * SIMD4<Float>(origin, 1)
        let d4 = inverse * SIMD4<Float>(direction, 0)
        let o = SIMD3<Float>(o4.x, o4.y, o4.z), d = SIMD3<Float>(d4.x, d4.y, d4.z)
        let low = SIMD3<Float>(-0.115, -0.02, -0.115), high = SIMD3<Float>(0.115, 0.175, 0.115)
        var enter: Float = 0, leave: Float = .greatestFiniteMagnitude
        for axis in 0..<3 {
            if abs(d[axis]) < 1e-7 {
                if o[axis] < low[axis] || o[axis] > high[axis] { return false }
            } else {
                let a = (low[axis] - o[axis]) / d[axis], b = (high[axis] - o[axis]) / d[axis]
                enter = max(enter, min(a, b))
                leave = min(leave, max(a, b))
            }
        }
        return leave > enter
    }
}

// A stable pinch can acquire immediately, including when entering the target already pinched.
// Missing observations are handled by the coordinator's short frozen-pose grace period.
struct PinchLatch {
    enum Event { case none, began, held, ended }
    private(set) var grabbed = false
    private var closingFrames = 0
    mutating func reset() { grabbed = false; closingFrames = 0 }
    mutating func update(_ ratio: Float?) -> Event {
        guard let ratio, ratio.isFinite else {
            let wasGrabbed = grabbed; reset()
            return wasGrabbed ? .ended : .none
        }
        if ratio > 0.65 {
            let wasGrabbed = grabbed
            grabbed = false; closingFrames = 0
            return wasGrabbed ? .ended : .none
        }
        if grabbed { return .held }
        if ratio < 0.40 {
            closingFrames += 1
            if closingFrames >= 2 { grabbed = true; return .began }
        } else { closingFrames = 0 }
        return .none
    }
}

enum SpectralTable {
    static func samples(count: Int) -> [SIMD4<Float>] {
        precondition(count >= 2)
        let a: Float = 1.62, b: Float = 0.012
        var weights = [SIMD3<Float>](), indices = [Float](), sum = SIMD3<Float>(repeating: 0)
        for i in 0..<count {
            let nm = 420 + 260*Float(i)/Float(count-1)
            let x = (SIMD3<Float>(repeating: nm)-SIMD3<Float>(610,545,455))/SIMD3<Float>(39,32,25)
            let w = SIMD3<Float>(exp(-0.5*x.x*x.x),exp(-0.5*x.y*x.y),exp(-0.5*x.z*x.z))
            weights.append(w); sum += w
            indices.append(a+b/pow(nm*0.001,2))
        }
        return weights.indices.map { SIMD4<Float>(weights[$0]/sum,indices[$0]) }
    }
}

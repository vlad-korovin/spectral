import Foundation
import simd

@main struct StudioTests {
    static func main() throws {
        func check(_ valid: Bool, _ message: String) {
            if !valid { fatalError(message) }
        }
        check(!InteractionMath.mayRecognizeTogether("rotation","other"), "rotation cannot trigger a pan")
        check(!InteractionMath.mayRecognizeTogether("other","pinch"), "pan cannot end during pinch")
        check(InteractionMath.mayRecognizeTogether("rotation","pinch"), "twist and scale may coexist")
        check(InteractionMath.mayRecognizeTogether("pan","pinch"), "a running drag must allow the second finger to acquire")
        check(!InteractionMath.mayRecognizeTogether("pan","other"), "placement tap must not coexist with manipulation")
        check(MemoryLayout<StudioLightUniforms>.stride == 80, "surface light GPU ABI")
        let rig = LightingRig(target: SIMD3<Float>(0,0,-1.5), right: SIMD3<Float>(1,0,0), towardCamera: SIMD3<Float>(0,0,1))
        let off = rig.uniforms(radius: 0.2, stops: 0, angle: 0, warmth: 0)
        check(off.sourceGain.w == 0, "zero stops must add no energy")
        let neutral = rig.uniforms(radius: 0.2, stops: 1, angle: 0, warmth: 0)
        check(abs(neutral.sourceGain.w-1)<1e-6, "one-stop target gain")
        check(neutral.colorSoftness.x == neutral.colorSoftness.z, "neutral fill is achromatic")
        let rotated = rig.uniforms(radius: 0.2, stops: 1, angle: .pi/2, warmth: 0)
        check(rotated.targetRadius == neutral.targetRadius, "moving source cannot move the subject target")
        check(abs(rotated.sourceGain.x-0.7)<1e-6, "quarter-turn places source at the target's right")
        var translatedRig = rig
        translatedRig.target += SIMD3<Float>(2,3,4)
        let translated = translatedRig.uniforms(radius: 0.2, stops: 1, angle: 0, warmth: 0)
        check(simd_distance(translated.sourceGain-neutral.sourceGain,SIMD4<Float>(2,3,4,0))<1e-6,
              "moving the setup preserves source-to-subject geometry")
        for style in LightingStyle.allCases {
            for angle: Float in [-Float.pi, -1, 0, 1, Float.pi] {
                let light = rig.uniforms(radius: 0.2, stops: 1, angle: angle, warmth: 0, style: style)
                let source = SIMD3<Float>(light.sourceGain.x, light.sourceGain.y, light.sourceGain.z)
                let axis = simd_normalize(rig.target-source)
                let right = SIMD3<Float>(light.shapeRight.x, light.shapeRight.y, light.shapeRight.z)
                check(abs(simd_dot(axis,right))<1e-6, "profile plane stays perpendicular to source direction")
                check(abs(simd_length(right)-1)<1e-6, "profile width has a normalized axis")
                check(light.shapeRight.w == Float(style.rawValue), "CPU/Metal lighting style identity")
            }
        }
        func idleAngle(fps: Int) -> Float {
            var motion = IdleCrystalMotion(), total: Float = 0
            for frame in 0...fps*20 {
                let delta = motion.step(at: Double(frame)/Double(fps), enabled: true)
                if frame <= fps*3 { check(delta == 0, "idle delay must preserve the pose") }
                check(delta >= 0 && delta <= 0.075/Float(fps)+1e-6, "bounded eased angular velocity")
                total += delta
            }
            return total
        }
        check(abs(idleAngle(fps: 30)-idleAngle(fps: 120))<2e-6, "idle speed is independent of frame rate")
        var motion = IdleCrystalMotion()
        for frame in 0...600 { _ = motion.step(at: Double(frame)/60, enabled: true) }
        check(motion.step(at: 10.01, enabled: false)==0, "touch pauses motion immediately")
        check(motion.step(at: 10.02, enabled: true)==0, "release never catches up skipped motion")
        check(motion.step(at: 50, enabled: true)==0, "session stall cannot jump the orientation")
        check(motion.step(at: 50.1, enabled: true)==0, "resume starts a fresh idle delay")
        check(motion.step(at: .nan, enabled: true)==0, "invalid time cannot poison the pose")
        var flight = IdleCrystalMotion()
        for frame in 0...60*20 {
            _ = flight.step(at: Double(frame)/60,enabled: true)
            check(flight.offset.y >= 0 && flight.offset.y<=0.13201, "flight height remains bounded above its anchor")
            check(abs(flight.offset.x)<=0.00801 && abs(flight.offset.z)<=0.01201, "hover orbit is bounded")
            check(flight.cinema>=0 && flight.cinema<=1, "cinematic lighting is bounded")
            if frame<=180 { check(flight.offset == .zero && flight.cinema==0,"lift and lighting share the three-second delay") }
        }
        let heldPose = flight.offset, heldLight = flight.cinema
        flight.pause(at: 20)
        for frame in 1...120 { _ = flight.step(at: 20+Double(frame)/60, enabled: false) }
        check(flight.offset == heldPose && flight.cinema == heldLight, "touch retains the visible airborne pose and lighting")
        for frame in 1...180 { _ = flight.step(at: 22+Double(frame)/60, enabled: true) }
        check(simd_distance(flight.offset,heldPose)<1e-7,"resuming never adds a second lift during the delay")
        for frame in 181...1200 { _ = flight.step(at: 22+Double(frame)/60, enabled: true) }
        check(flight.offset.y<0.133,"repeated activity cannot accumulate altitude")
        flight.land(at: 42)
        let landingStart = flight.offset
        _ = flight.step(at: 42,enabled: false)
        check(flight.offset == landingStart,"landing begins at the visible pose")
        for frame in 1...90 { _ = flight.step(at: 42+Double(frame)/60,enabled: false) }
        check(flight.offset == .zero && flight.cinema==0 && !flight.isLanding,"rest returns to anchor and normal lighting")
        let spacePoint = SIMD3<Float>(0.2,0.6,-1), normal = SIMD3<Float>(0,0,1)
        let spaceHit = InteractionMath.dragPlaneHit(origin: .zero,direction: simd_normalize(spacePoint),point: spacePoint,normal: normal)!
        check(simd_distance(spaceHit,spacePoint)<1e-6,"free-space ray reaches a vertical drag plane")
        check(InteractionMath.dragPlaneHit(origin: .zero,direction: SIMD3<Float>(1,0,0),point: spacePoint,normal: normal)==nil,"grazing 3D drags are rejected")
        let displacedCamera = SIMD3<Float>(0.1,0.2,0)
        let movedHit = InteractionMath.dragPlaneHit(origin: displacedCamera,direction: simd_normalize(spacePoint-displacedCamera),point: spacePoint,normal: normal)!
        check(simd_distance(movedHit,spacePoint)<1e-6,"camera motion preserves the fixed world drag plane")
        check(abs(InteractionMath.gestureScale(start: 1.2,magnification: 1.5)-1.8)<1e-6,
              "pinch uses its stable begin state")
        check(InteractionMath.gestureScale(start: 2,magnification: 2)==2.2,
              "pinch clamps the maximum size")
        check(InteractionMath.gestureScale(start: 0.5,magnification: 0.2)==0.4,
              "pinch clamps the minimum size")
        let wrappedYaw = InteractionMath.gestureYaw(start: 3.1,rotation: -0.2)
        check(wrappedYaw >= -.pi && wrappedYaw <= .pi, "rotation remains numerically bounded")
        let start = SIMD3<Float>(0.1,0.7,-0.8), grip = SIMD3<Float>(0.3,0.7,-1)
        check(InteractionMath.dragTranslation(startPosition: start, startHit: grip, currentHit: grip) == start,
              "touch offset must not snap object under the finger")
        let shifted = InteractionMath.dragTranslation(startPosition: start, startHit: grip, currentHit: grip+SIMD3<Float>(0.2,0,0.1))
        check(simd_distance(shifted,start+SIMD3<Float>(0.2,0,0.1))<1e-6, "drag preserves height and grip offset")
        check(InteractionMath.planeHit(origin: SIMD3<Float>(0,1,0),direction: SIMD3<Float>(1,0,0),height: 0) == nil,
              "grazing rays cannot launch the object to infinity")
        let floor = InteractionMath.planeHit(origin: SIMD3<Float>(0,1,0),direction: SIMD3<Float>(0,-1,0),height: 0)!
        check(floor == .zero, "ray to fixed support plane")
        check(InteractionMath.touchesGlass(origin: SIMD3<Float>(0,0.07,1),direction: SIMD3<Float>(0,0,-1),
            model: matrix_identity_float4x4), "touch on object accepted")
        check(!InteractionMath.touchesGlass(origin: SIMD3<Float>(1,1,1),direction: SIMD3<Float>(0,0,-1),
            model: matrix_identity_float4x4), "touch far from glass cannot drag it")
        var ownership = InteractionOwnership()
        check(ownership.allowsHands(now: 1,sampleTime: 0.9),"hands are automatically eligible before touch")
        ownership.touch(at: 1)
        check(!ownership.allowsHands(now: 1.2,sampleTime: 1.15),"touch has immediate priority over new hand results")
        check(!ownership.allowsHands(now: 1.45,sampleTime: 0.99),"pre-touch Vision samples cannot reclaim ownership")
        check(ownership.allowsHands(now: 1.5,sampleTime: 1.45),"fresh hands resume automatically after touch grace")
        ownership.touch(at: 1.5)
        check(!ownership.allowsHands(now: 1.8,sampleTime: 1.75),"holding a screen touch renews priority")
        check(!ownership.allowsHands(now: 2,sampleTime: 2.1),"future samples are invalid")
        check(!ownership.allowsHands(now: 3,sampleTime: 2.5),"stale hand poses cannot move a crystal")
        check(InteractionMath.reliableHandDepth([.nan,0,0.5,0.501,0.502,0.503,0.499]) != nil,"compact confident palm patch is usable")
        check(InteractionMath.reliableHandDepth([0.5,0.5,0.5,0.5]) == nil,"sparse depth cannot drive hand distance")
        check(InteractionMath.reliableHandDepth([0.4,0.4,0.41,0.8,0.8,0.8]) == nil,"hand/background boundary rejected")
        check(InteractionMath.reliableHandDepth([2,2,2,2,2]) == nil,"distant background cannot become palm depth")
        let grab = CrystalHandGrab(position: SIMD3<Float>(0.1,0.2,-0.8),grip: SIMD3<Float>(0.3,0.1,-0.4),
            normal: SIMD3<Float>(0,0,1),usesDepth: true,sampleTime: 0)
        check(grab.target(for: grab.grip)==grab.position,"hand acquisition preserves crystal/palm offset")
        let move=SIMD3<Float>(0.1,0.3,0.2)
        check(simd_distance(grab.target(for: grab.grip+move),grab.position+move)<1e-6,"hand lifting and depth affect all three world axes")
        let a12=InteractionMath.handSmoothing(dt: 1.0/12), a24=InteractionMath.handSmoothing(dt: 1.0/24)
        check(abs((1-a12)-(1-a24)*(1-a24))<1e-6,"hand smoothing uses elapsed time, not detector frame rate")
        var latch = PinchLatch()
        check(latch.update(0.3) == .none, "one closing sample must not grab")
        check(latch.update(0.3) == .began, "stable relaxed pinch acquires without an open-hand ritual")
        check(latch.update(0.5) == .held, "wide hysteresis prevents threshold chatter")
        check(latch.update(0.8) == .ended, "open hand releases")
        check(latch.update(0.3) == .none, "reacquisition remains debounced")
        check(latch.update(0.3) == .began, "reacquisition does not require exaggerated finger separation")
        check(latch.update(nil) == .ended, "explicit reset safely releases")
        let native = SIMD2<Float>(0.2,0.7)
        for (orientation, vision) in [(1,SIMD2<Float>(0.2,0.3)),(3,SIMD2<Float>(0.8,0.7)),
                                      (6,SIMD2<Float>(0.3,0.8)),(8,SIMD2<Float>(0.7,0.2))] {
            check(simd_distance(InteractionMath.sensorPoint(vision: vision,orientation: orientation),native)<1e-6,
                  "Vision orientation must map back to native ARKit pixels")
        }
        for count in [13,31,25] {
            let table = SpectralTable.samples(count: count)
            var white = SIMD3<Float>(repeating: 0)
            for sample in table {
                check(sample.x>=0 && sample.y>=0 && sample.z>=0,"positive spectral contributions")
                white += SIMD3<Float>(sample.x,sample.y,sample.z)
            }
            check(simd_distance(white,SIMD3<Float>(repeating: 1))<1e-5,"precomputation must preserve neutral energy")
            check(table.first!.w>table.last!.w,"blue index remains greater than red")
        }
        let depth: [Float] = [1,2,3,4]
        let rawDepth = depth.withUnsafeBytes { Data($0) }
        let zip = StoredZIP.archive([("metadata.json",Data("{\"schema\":\"test\"}".utf8)),
                                     ("depth.f32",rawDepth), ("empty.bin",Data()), ("unicode-é.txt",Data("prism".utf8))])
        try zip.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("PASS: automatic ownership, 3D grab/depth guards, gestures, idle motion, spectrum; archive written for independent ZIP verification")
    }
}

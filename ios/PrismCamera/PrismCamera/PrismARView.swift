import ARKit
import MetalKit
import SwiftUI

struct PrismARView: UIViewRepresentable {
    @ObservedObject var studio: StudioState

    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.owner = self
        context.coordinator.syncControls()
        context.coordinator.syncSavedRig()
        if context.coordinator.resetToken != studio.resetToken {
            context.coordinator.resetToken = studio.resetToken
            context.coordinator.clear()
        }
        if context.coordinator.captureToken != studio.captureToken {
            context.coordinator.captureToken = studio.captureToken
            context.coordinator.renderer?.captureDataset = studio.datasetCapture
            context.coordinator.renderer?.captureRequested = true
            if context.coordinator.session.currentFrame == nil {
                studio.capturing = false
                studio.error = "Wait for the camera to start."
                context.coordinator.renderer?.captureRequested = false
            }
        }
    }

    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
        coordinator.endHandGrab()
        coordinator.handTracker.cancel()
        coordinator.session.pause()
        view.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency ARSessionDelegate,
        UIGestureRecognizerDelegate
    {
        var owner: PrismARView
        var resetToken: UUID
        var captureToken: UUID
        let session = ARSession()
        var renderer: OpticalRenderer?
        weak var view: MTKView?
        var anchor: ARAnchor?
        var probe: AREnvironmentProbeAnchor?
        var yaw: Float = 0
        var scale: Float = 1
        var lastStatusTime: TimeInterval = 0
        let handTracker = HandTracker()
        var pinchLatch = PinchLatch()
        var handGrab: CrystalHandGrab?
        var lastHandTime: TimeInterval = 0
        var handEnabled = false
        var dragStart: (position: SIMD3<Float>, hit: SIMD3<Float>, normal: SIMD3<Float>)?
        var pinchStartScale: Float?
        var rotationStartYaw: Float?
        var activeLightTool = false
        var lightDragging = false
        var idleMotion = IdleCrystalMotion()
        var restToken: UUID
        var activePlacementMode: CrystalPlacement = .space
        var ownership = InteractionOwnership()
        var saveRigToken: UUID?
        var restoreRigToken: UUID?
        var savedRig:
            (
                rig: LightingRig, radius: Float, stops: Float, angle: Float, warmth: Float,
                style: LightingStyle
            )?

        init(owner: PrismARView) {
            self.owner = owner
            resetToken = owner.studio.resetToken
            captureToken = owner.studio.captureToken
            restToken = owner.studio.restToken
        }

        func syncControls() {
            syncSpatialControls()
            renderer?.cinematicStrength = owner.studio.cinematicIdle ? idleMotion.cinema : 0
            if activeLightTool != owner.studio.lightTool {
                if handGrab != nil { endHandGrab() }
                finishDrag()
                pinchStartScale = nil
                rotationStartYaw = nil
                lightDragging = false
                activeLightTool = owner.studio.lightTool
                // Invalidate recognizers still holding the previous instrument's touches.
                view?.gestureRecognizers?.forEach {
                    $0.isEnabled = false
                    $0.isEnabled = true
                }
            }
            let enabled =
                !owner.studio.lightTool && owner.studio.automaticHands && !owner.studio.motionPaused
                && !owner.studio.capturing && !owner.studio.compare && !owner.studio.showDepth
            if owner.studio.touchingControls { takeTouchControl() }
            if enabled != handEnabled {
                endHandGrab()
                handTracker.cancel()
                handEnabled = enabled
            }
            renderer?.roomCaustics = owner.studio.roomCaustics
            renderer?.setLightLocked(owner.studio.lightLocked)
            renderer?.compare = owner.studio.compare
            renderer?.showDepth = owner.studio.showDepth
            renderer?.detail = owner.studio.detail
            if let rig = renderer?.lightingRig {
                renderer?.studioLight = rig.uniforms(
                    radius: owner.studio.lightRadius, stops: owner.studio.lightStops,
                    angle: owner.studio.lightAngle, warmth: owner.studio.lightWarmth,
                    style: owner.studio.lightStyle)
                renderer?.studioLight.normalEnabled.w = owner.studio.fillEnabled ? 1 : 0
            }
        }

        private func dragNormal(at position: SIMD3<Float>) -> SIMD3<Float> {
            if owner.studio.placementMode == .space || idleMotion.offset.y > 0.001,
                let camera = session.currentFrame?.camera.transform
            {
                let z = camera.columns.2
                return simd_normalize(SIMD3<Float>(z.x, z.y, z.z))
            }
            return SIMD3<Float>(0, 1, 0)
        }

        private func setCinematicAxis(at position: SIMD4<Float>) {
            guard let camera = session.currentFrame?.camera.transform else { return }
            let delta = camera.columns.3 - position
            let x = camera.columns.0
            let toward = SIMD3<Float>(delta.x, delta.y, delta.z)
            guard simd_length_squared(toward) > 0.001 else { return }
            renderer?.cinematicAxis = simd_normalize(
                simd_normalize(toward) + SIMD3<Float>(x.x, x.y, x.z) * 0.8 + SIMD3<Float>(0, 0.6, 0)
            )
        }

        private func updateReceiver(below position: SIMD3<Float>) {
            let query = ARRaycastQuery(
                origin: position + SIMD3<Float>(0, 0.01, 0), direction: SIMD3<Float>(0, -1, 0),
                allowing: .existingPlaneGeometry, alignment: .horizontal)
            renderer?.receiverHeight = session.raycast(query).first?.worldTransform.columns.3.y
        }

        private func takeTouchControl() {
            let time = session.currentFrame?.timestamp ?? 0
            ownership.touch(at: time)
            handTracker.cancel()
            endHandGrab()
            idleMotion.pause(at: time)
        }

        private func syncSpatialControls() {
            let state = owner.studio
            let time = session.currentFrame?.timestamp ?? 0
            if activePlacementMode != state.placementMode {
                if handGrab != nil { endHandGrab() }
                finishDrag()
                idleMotion.pause(at: time)
                activePlacementMode = state.placementMode
                pinchStartScale = nil
                rotationStartYaw = nil
                view?.gestureRecognizers?.forEach {
                    $0.isEnabled = false
                    $0.isEnabled = true
                }
            }
            if restToken != state.restToken {
                restToken = state.restToken
                if handGrab != nil { endHandGrab() }
                finishDrag()
                if state.reduceMotion {
                    // Explicit Rest still works with Reduce Motion, without an animated transition.
                    idleMotion.clear(at: time)
                    renderer?.motionOffset = .zero
                    renderer?.cinematicStrength = 0
                } else {
                    idleMotion.land(at: time)
                }
            }
        }

        func syncSavedRig() {
            let state = owner.studio
            if saveRigToken == nil { saveRigToken = state.saveRigToken }
            if restoreRigToken == nil { restoreRigToken = state.restoreRigToken }
            if saveRigToken != state.saveRigToken {
                saveRigToken = state.saveRigToken
                if let rig = renderer?.lightingRig {
                    savedRig = (
                        rig, state.lightRadius, state.lightStops, state.lightAngle,
                        state.lightWarmth, state.lightStyle
                    )
                    DispatchQueue.main.async {
                        state.hasSavedRig = true
                        state.lightHint = "Setup remembered for this session"
                    }
                }
            }
            if restoreRigToken != state.restoreRigToken {
                restoreRigToken = state.restoreRigToken
                if let saved = savedRig {
                    renderer?.lightingRig = saved.rig
                    DispatchQueue.main.async {
                        state.lightRadius = saved.radius
                        state.lightStops = saved.stops
                        state.lightAngle = saved.angle
                        state.lightWarmth = saved.warmth
                        state.lightStyle = saved.style
                        state.lightHint = "Setup recalled · Camera and subject stay live"
                    }
                }
            }
        }

        func attach(_ view: MTKView) {
            self.view = view
            do {
                renderer = try OpticalRenderer(view: view, session: session)
            } catch {
                publish("Renderer unavailable: \(error.localizedDescription)")
                return
            }
            syncControls()
            renderer?.onPerformance = { [weak self] text in self?.owner.studio.performance = text }
            renderer?.onCapture = { [weak self] result in
                guard let self else { return }
                self.owner.studio.capturing = false
                switch result {
                case .success(let url): self.owner.studio.export = CaptureExport(url: url)
                case .failure(let error): self.owner.studio.error = error.localizedDescription
                }
            }
            handTracker.onSample = { [weak self] sample in self?.consumeHand(sample) }
            session.delegate = self
            session.delegateQueue = .main
            let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
            let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
            pan.minimumNumberOfTouches = 1
            pan.maximumNumberOfTouches = 1
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
            let rotation = UIRotationGestureRecognizer(target: self, action: #selector(rotate(_:)))
            tap.require(toFail: pan)
            tap.require(toFail: pinch)
            tap.require(toFail: rotation)
            for recognizer in [tap, pan, pinch, rotation] {
                recognizer.delegate = self
                view.addGestureRecognizer(recognizer)
            }
            guard ARWorldTrackingConfiguration.isSupported else {
                publish("Live optics requires a physical iPhone with ARKit.")
                return
            }
            let config = ARWorldTrackingConfiguration()
            config.planeDetection = [.horizontal]
            config.environmentTexturing = .manual
            config.isLightEstimationEnabled = true
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                // Raw depth avoids temporal trails when a hand crosses the glass.
                config.frameSemantics.insert(.sceneDepth)
            }
            if let format = ARWorldTrackingConfiguration.supportedVideoFormats
                .filter({ $0.framesPerSecond == 60 })
                .min(by: { $0.imageResolution.width < $1.imageResolution.width })
            {
                config.videoFormat = format
            }
            session.run(config)
        }

        func publish(_ text: String) {
            guard owner.studio.status != text else { return }
            DispatchQueue.main.async { [weak self] in self?.owner.studio.status = text }
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            let tracking: Bool
            if case .normal = frame.camera.trackingState {
                tracking = true
            } else {
                tracking = false
            }
            let state = owner.studio
            let touching =
                state.touchingControls
                || (view?.gestureRecognizers?.contains { $0.numberOfTouches > 0 } ?? false)
            if touching { ownership.touch(at: frame.timestamp) }
            let handVisible = state.handPoint != nil && frame.timestamp - lastHandTime < 0.45
            let canAdvance =
                anchor != nil && tracking && !state.reduceMotion && !state.motionPaused
                && !state.rigLocked && !state.capturing && !state.compare && !state.showDepth
                && handGrab == nil && (!handVisible || idleMotion.isLanding) && !touching
                && dragStart == nil && pinchStartScale == nil && rotationStartYaw == nil
            if !canAdvance { idleMotion.pause(at: frame.timestamp) }
            let turn = idleMotion.step(
                at: frame.timestamp, enabled: canAdvance && state.idleAnimation)
            if turn != 0 {
                yaw = InteractionMath.gestureYaw(start: yaw, rotation: -turn)
                renderer?.yaw = yaw
            }
            // All optical passes consume the same bounded world-space motion offset.
            renderer?.motionOffset = idleMotion.offset
            renderer?.cinematicStrength = state.cinematicIdle ? idleMotion.cinema : 0
            if frame.timestamp - lastHandTime > 0.45, handGrab != nil || state.handPoint != nil {
                endHandGrab()
            }
            if handEnabled, anchor != nil, !touching,
                ownership.allowsHands(now: frame.timestamp, sampleTime: frame.timestamp)
            {
                if tracking {
                    let orientation = view?.window?.windowScene?.interfaceOrientation ?? .portrait
                    let exif: CGImagePropertyOrientation =
                        orientation == .portrait
                        ? .right
                        : orientation == .portraitUpsideDown
                            ? .left : orientation == .landscapeRight ? .down : .up
                    handTracker.submit(
                        frame, orientation: exif, active: handVisible || handGrab != nil)
                } else {
                    endHandGrab()
                    handTracker.cancel()
                }
            }
            guard frame.timestamp - lastStatusTime > 0.5 else { return }
            lastStatusTime = frame.timestamp
            switch frame.camera.trackingState {
            case .normal:
                if owner.studio.lightTool {
                    publish(
                        frame.sceneDepth == nil
                            ? "Surface fill needs LiDAR depth"
                            : (owner.studio.lightPlaced
                                ? "Surface fill · Compose and capture"
                                : "Frame your subject, then tap to aim"))
                } else if anchor == nil {
                    publish(
                        state.placementMode == .space
                            ? "Ready to place"
                            : "Scan a surface, then tap to place")
                } else if renderer?.gpuFailed == true {
                    publish("Rendering interrupted — waiting for graphics to recover")
                } else {
                    let reflection = frame.anchors.contains {
                        ($0 as? AREnvironmentProbeAnchor)?.environmentTexture != nil
                    }
                    if owner.studio.lightLocked, renderer?.hasLockedLighting == true {
                        publish("Light locked — frame, shape, capture")
                    } else {
                        publish(
                            reflection
                                ? "Light found — twist the crystal to shape it"
                                : "Move slowly to map windows and lamps")
                    }
                }
            case .limited: publish("Move slowly — rebuilding tracking")
            case .notAvailable: publish("Tracking unavailable")
            }
        }

        func session(_ session: ARSession, didFailWithError error: Error) {
            publish(error.localizedDescription)
        }

        func sessionWasInterrupted(_ session: ARSession) { publish("Camera paused") }
        func sessionInterruptionEnded(_ session: ARSession) { clear() }

        private func cameraRay(_ point: CGPoint) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)?
        {
            guard let view, let frame = session.currentFrame,
                view.bounds.width > 0, view.bounds.height > 0
            else { return nil }
            let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
            let projection = frame.camera.projectionMatrix(
                for: orientation, viewportSize: view.bounds.size, zNear: 0.01, zFar: 20)
            let inverse = simd_inverse(projection * frame.camera.viewMatrix(for: orientation))
            let clip = SIMD4<Float>(
                Float(point.x / view.bounds.width) * 2 - 1,
                1 - Float(point.y / view.bounds.height) * 2, 0.5, 1)
            let world = inverse * clip
            let origin = SIMD3<Float>(
                frame.camera.transform.columns.3.x, frame.camera.transform.columns.3.y,
                frame.camera.transform.columns.3.z)
            let target = SIMD3<Float>(world.x, world.y, world.z) / world.w
            return (origin, simd_normalize(target - origin))
        }

        private func hit(_ point: CGPoint) -> ARRaycastResult? {
            guard let ray = cameraRay(point) else { return nil }
            let query = ARRaycastQuery(
                origin: ray.origin, direction: ray.direction,
                allowing: .existingPlaneGeometry, alignment: .horizontal)
            return session.raycast(query).first
        }

        private func place(_ result: ARRaycastResult) {
            idleMotion.clear(at: session.currentFrame?.timestamp ?? 0)
            renderer?.motionOffset = .zero
            renderer?.receiverHeight = result.worldTransform.columns.3.y
            var transform = matrix_identity_float4x4
            transform.columns.3 = result.worldTransform.columns.3
            setCinematicAxis(at: transform.columns.3)
            commitPlacement(transform)
        }

        private func commitPlacement(_ transform: simd_float4x4) {
            if let anchor { session.remove(anchor: anchor) }
            let next = ARAnchor(name: "Spectral crystal", transform: transform)
            session.add(anchor: next)
            anchor = next
            if !owner.studio.placed { owner.studio.placed = true }
            renderer?.anchorID = next.identifier
            renderer?.placement = transform
            renderer?.placementOverride = nil
            renderer?.yaw = yaw
            renderer?.objectScale = scale
            // Keep captured reflections during small adjustments instead of recapturing every time.
            if probe == nil || simd_distance(probe!.transform.columns.3, transform.columns.3) > 0.5
            {
                if let probe { session.remove(anchor: probe) }
                let nextProbe = AREnvironmentProbeAnchor(
                    transform: transform, extent: SIMD3<Float>(repeating: 2))
                session.add(anchor: nextProbe)
                probe = nextProbe
            }
            if owner.studio.placementMode == .space, let visible = renderer?.visiblePlacement {
                let p = visible.columns.3
                updateReceiver(below: SIMD3<Float>(p.x, p.y, p.z))
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }

        // A fresh placement resets the crystal pose, not the room or lighting setup.
        private func resetCrystalPoseForPlacement() {
            yaw = 0
            scale = 1
            dragStart = nil
            pinchStartScale = nil
            rotationStartYaw = nil
            idleMotion.clear(at: session.currentFrame?.timestamp ?? 0)
            renderer?.motionOffset = .zero
            renderer?.cinematicStrength = 0
            renderer?.placementOverride = nil
        }

        @objc func tap(_ gesture: UITapGestureRecognizer) {
            if owner.studio.lightTool {
                if gesture.state == .ended { aimLight(at: gesture.location(in: view)) }
                return
            }
            guard gesture.state == .ended else { return }
            guard renderer != nil else {
                owner.studio.placementHint = "Graphics unavailable. Reopen Spectral to try again."
                return
            }
            guard let frame = session.currentFrame, case .normal = frame.camera.trackingState else {
                owner.studio.placementHint = "Move slowly, then tap again when tracking settles."
                return
            }
            takeTouchControl()
            if owner.studio.placementMode == .space, let ray = cameraRay(gesture.location(in: view))
            {
                resetCrystalPoseForPlacement()
                var transform = matrix_identity_float4x4
                let base = ray.origin + ray.direction * 0.75 - SIMD3<Float>(0, 0.0725 * scale, 0)
                transform.columns.3 = SIMD4<Float>(base, 1)
                setCinematicAxis(at: transform.columns.3)
                updateReceiver(below: base)
                commitPlacement(transform)
                owner.studio.placementHint = nil
                return
            }
            guard let result = hit(gesture.location(in: view)) else {
                owner.studio.placementHint = "No surface found. Scan a little, then tap another spot."
                return
            }
            resetCrystalPoseForPlacement()
            place(result)
            owner.studio.placementHint = nil
        }

        func endHandGrab(keepCursor: Bool = false) {
            if handGrab != nil {
                if let transform = renderer?.placementOverride { commitPlacement(transform) }
                renderer?.placementOverride = nil
            }
            handGrab = nil
            pinchLatch.reset()
            if !keepCursor && owner.studio.handPoint != nil { owner.studio.handPoint = nil }
            if owner.studio.handGrabbing { owner.studio.handGrabbing = false }
            if owner.studio.handStatus != "Pinch over the crystal, then lift your hand" {
                owner.studio.handStatus = "Pinch over the crystal, then lift your hand"
            }
        }

        func consumeHand(_ sample: HandSample?) {
            guard handEnabled, !owner.studio.touchingControls, let renderer,
                let transform = renderer.visiblePlacement, let current = session.currentFrame
            else { return }
            guard let sample else {
                if current.timestamp - lastHandTime > 0.4 {
                    endHandGrab()
                } else if handGrab != nil {
                    owner.studio.handStatus = "Hand hidden · Holding your crystal"
                }
                return
            }
            guard ownership.allowsHands(now: current.timestamp, sampleTime: sample.frame.timestamp),
                dragStart == nil, pinchStartScale == nil, rotationStartYaw == nil,
                case .normal = current.camera.trackingState, let view
            else { return }
            lastHandTime = current.timestamp
            let frame = sample.frame
            let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
            let cursor = sample.sensorPoint.applying(
                frame.displayTransform(for: orientation, viewportSize: view.bounds.size))
            guard cursor.x >= 0, cursor.x <= 1, cursor.y >= 0, cursor.y <= 1 else {
                endHandGrab()
                return
            }
            owner.studio.handPoint = cursor
            idleMotion.pause(at: current.timestamp)
            let k = frame.camera.intrinsics
            let size = frame.camera.imageResolution
            let direction = SIMD3<Float>(
                (Float(sample.sensorPoint.x * size.width) - k[2][0]) / k[0][0],
                -(Float(sample.sensorPoint.y * size.height) - k[2][1]) / k[1][1], -1)
            let world = frame.camera.transform * SIMD4<Float>(direction, 0)
            let camera = frame.camera.transform.columns.3
            let origin = SIMD3<Float>(camera.x, camera.y, camera.z)
            let ray = simd_normalize(SIMD3<Float>(world.x, world.y, world.z))
            let p = transform.columns.3
            let position = SIMD3<Float>(p.x, p.y, p.z)
            let axis = frame.camera.transform.columns.2
            let normal = handGrab?.normal ?? simd_normalize(SIMD3<Float>(axis.x, axis.y, axis.z))
            let planeHit = InteractionMath.dragPlaneHit(
                origin: origin, direction: ray, point: handGrab?.position ?? position,
                normal: normal)
            let event = pinchLatch.update(sample.pinchRatio)
            if event == .began || event == .held, handGrab == nil {
                var local = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0)))
                for i in 0..<3 { local[i] *= scale }
                if InteractionMath.touchesGlass(
                    origin: origin, direction: ray, model: transform * local),
                    let grip = sample.palmWorldPosition ?? planeHit
                {
                    handGrab = CrystalHandGrab(
                        position: position, grip: grip, normal: normal,
                        usesDepth: sample.palmWorldPosition != nil, sampleTime: frame.timestamp)
                    owner.studio.handGrabbing = true
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                }
            } else if event == .held, var grab = handGrab {
                // Never switch between measured depth and the fallback plane mid-grab.
                guard let point = grab.usesDepth ? sample.palmWorldPosition : planeHit else {
                    owner.studio.handStatus = "Hold steady · Finding your hand"
                    return
                }
                let target = grab.target(for: point)
                let previous = renderer.visiblePlacement?.columns.3 ?? transform.columns.3
                let old = SIMD3<Float>(previous.x, previous.y, previous.z)
                let dt = frame.timestamp - grab.sampleTime
                guard dt > 0, simd_distance(target, grab.position) < 1.2,
                    simd_distance(old, target) < Float(min(0.25, 0.03 + 1.8 * dt))
                else {
                    endHandGrab()
                    return
                }
                let smooth = old + (target - old) * InteractionMath.handSmoothing(dt: dt)
                var next = matrix_identity_float4x4
                next.columns.3 = SIMD4<Float>(smooth, 1)
                renderer.placementOverride = renderer.basePlacement(fromVisible: next)
                grab.sampleTime = frame.timestamp
                handGrab = grab
            } else if event == .ended {
                endHandGrab(keepCursor: true)
                return
            }
            owner.studio.handStatus =
                handGrab == nil
                ? "Pinch over the crystal to catch it"
                : ((handGrab!.usesDepth
                    ? "Lift, sweep, bring closer · Open to release"
                    : "Lift and sweep · Open to release"))
        }

        private func finishDrag() {
            if dragStart != nil, let transform = renderer?.placementOverride {
                commitPlacement(transform)
            }
            dragStart = nil
            renderer?.placementOverride = nil
        }

        private func aimLight(at point: CGPoint) {
            guard !owner.studio.rigLocked, let view, let frame = session.currentFrame,
                case .normal = frame.camera.trackingState,
                let depth = frame.sceneDepth, let confidence = depth.confidenceMap,
                let ray = cameraRay(point)
            else {
                if !owner.studio.rigLocked {
                    owner.studio.lightHint = "Move slowly — reliable scene depth is needed"
                }
                return
            }
            let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
            let uv = CGPoint(x: point.x / view.bounds.width, y: point.y / view.bounds.height)
                .applying(
                    frame.displayTransform(for: orientation, viewportSize: view.bounds.size)
                        .inverted())
            guard uv.x >= 0, uv.x < 1, uv.y >= 0, uv.y < 1 else { return }
            let map = depth.depthMap
            let w = CVPixelBufferGetWidth(map)
            let h = CVPixelBufferGetHeight(map)
            CVPixelBufferLockBaseAddress(map, .readOnly)
            CVPixelBufferLockBaseAddress(confidence, .readOnly)
            defer {
                CVPixelBufferUnlockBaseAddress(map, .readOnly)
                CVPixelBufferUnlockBaseAddress(confidence, .readOnly)
            }
            guard let base = CVPixelBufferGetBaseAddress(map),
                let cb = CVPixelBufferGetBaseAddress(confidence)
            else { return }
            let x = min(w - 1, Int(uv.x * Double(w)))
            let y = min(h - 1, Int(uv.y * Double(h)))
            let z = base.advanced(by: y * CVPixelBufferGetBytesPerRow(map)).assumingMemoryBound(
                to: Float.self)[x]
            let reliable = cb.advanced(by: y * CVPixelBufferGetBytesPerRow(confidence))
                .assumingMemoryBound(to: UInt8.self)[x]
            guard reliable >= 1, z.isFinite, z > 0.1, z < 5 else {
                owner.studio.lightHint = "Aim at a solid, matte surface with visible detail"
                return
            }
            let cameraDirection =
                simd_inverse(frame.camera.transform) * SIMD4<Float>(ray.direction, 0)
            guard -cameraDirection.z > 0.05 else { return }
            let target = ray.origin + ray.direction * (z / -cameraDirection.z)
            if lightDragging, let old = renderer?.lightingRig,
                simd_distance(old.target, target) > 0.3
            {
                return
            }
            if var rig = renderer?.lightingRig {
                rig.target = target
                renderer?.lightingRig = rig
            } else {
                let toward = simd_normalize(ray.origin - target)
                let xAxis = frame.camera.transform.columns.0
                let rawRight = SIMD3<Float>(xAxis.x, xAxis.y, xAxis.z)
                let right = simd_normalize(rawRight - toward * simd_dot(rawRight, toward))
                renderer?.lightingRig = LightingRig(
                    target: target, right: right, towardCamera: toward)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            owner.studio.lightPlaced = true
            owner.studio.lightHint = "Drag to aim · Pinch to widen · Twist to move source"
            syncControls()
        }

        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            guard let frame = session.currentFrame, case .normal = frame.camera.trackingState else {
                finishDrag()
                lightDragging = false
                return
            }
            if owner.studio.lightTool {
                switch gesture.state {
                case .began:
                    aimLight(at: gesture.location(in: view))
                    lightDragging = true
                case .changed:
                    if gesture.numberOfTouches == 1, pinchStartScale == nil, rotationStartYaw == nil
                    {
                        aimLight(at: gesture.location(in: view))
                    }
                case .ended, .cancelled, .failed: lightDragging = false
                default: break
                }
                return
            }
            guard anchor != nil, let renderer else { return }
            switch gesture.state {
            case .began:
                guard let transform = renderer.visiblePlacement,
                    let ray = cameraRay(gesture.location(in: view))
                else { return }
                var local = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0)))
                for i in 0..<3 { local[i] *= scale }
                let p = transform.columns.3
                let position = SIMD3<Float>(p.x, p.y, p.z)
                let normal = dragNormal(at: position)
                guard
                    InteractionMath.touchesGlass(
                        origin: ray.origin, direction: ray.direction, model: transform * local),
                    let point = InteractionMath.dragPlaneHit(
                        origin: ray.origin, direction: ray.direction, point: position,
                        normal: normal)
                else { return }
                dragStart = (position, point, normal)
            case .changed:
                guard let start = dragStart, pinchStartScale == nil, rotationStartYaw == nil,
                    gesture.numberOfTouches == 1,
                    let ray = cameraRay(gesture.location(in: view)),
                    let point = InteractionMath.dragPlaneHit(
                        origin: ray.origin, direction: ray.direction, point: start.position,
                        normal: start.normal)
                else { return }
                let position = start.position + (point - start.hit)
                guard simd_distance(position, start.position) < 1 else { return }
                var transform = matrix_identity_float4x4
                transform.columns.3 = SIMD4<Float>(position, 1)
                renderer.placementOverride = renderer.basePlacement(fromVisible: transform)
            case .ended:
                if dragStart != nil, let transform = renderer.placementOverride {
                    commitPlacement(transform)
                }
                dragStart = nil
                renderer.placementOverride = nil
            case .cancelled:
                // A second finger intentionally hands control to pinch/rotation. Preserve
                // the completed one-finger move instead of snapping back to its start.
                if dragStart != nil, let transform = renderer.placementOverride {
                    commitPlacement(transform)
                }
                dragStart = nil
                renderer.placementOverride = nil
            case .failed:
                dragStart = nil
                renderer.placementOverride = nil
            default: break
            }
        }

        @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
            if owner.studio.lightTool {
                guard owner.studio.lightPlaced, !owner.studio.rigLocked else {
                    pinchStartScale = nil
                    return
                }
                switch gesture.state {
                case .began: pinchStartScale = owner.studio.lightRadius
                case .changed, .ended:
                    if let start = pinchStartScale {
                        owner.studio.lightRadius = min(0.8, max(0.06, start * Float(gesture.scale)))
                        syncControls()
                    }
                    if gesture.state == .ended { pinchStartScale = nil }
                case .cancelled, .failed: pinchStartScale = nil
                default: break
                }
                return
            }
            guard anchor != nil else { return }
            switch gesture.state {
            case .began:
                finishDrag()
                pinchStartScale = scale
            case .changed:
                guard let start = pinchStartScale else { return }
                scale = InteractionMath.gestureScale(
                    start: start, magnification: Float(gesture.scale))
                renderer?.objectScale = scale
            case .ended:
                if let start = pinchStartScale {
                    scale = InteractionMath.gestureScale(
                        start: start, magnification: Float(gesture.scale))
                    renderer?.objectScale = scale
                }
                pinchStartScale = nil
            case .cancelled, .failed:
                pinchStartScale = nil
            default: break
            }
        }

        @objc func rotate(_ gesture: UIRotationGestureRecognizer) {
            if owner.studio.lightTool {
                guard owner.studio.lightPlaced, !owner.studio.rigLocked else {
                    rotationStartYaw = nil
                    return
                }
                switch gesture.state {
                case .began: rotationStartYaw = owner.studio.lightAngle
                case .changed, .ended:
                    if let start = rotationStartYaw {
                        owner.studio.lightAngle = InteractionMath.gestureYaw(
                            start: start, rotation: Float(gesture.rotation))
                        syncControls()
                    }
                    if gesture.state == .ended { rotationStartYaw = nil }
                case .cancelled, .failed: rotationStartYaw = nil
                default: break
                }
                return
            }
            guard anchor != nil else { return }
            switch gesture.state {
            case .began:
                finishDrag()
                rotationStartYaw = yaw
            case .changed:
                guard let start = rotationStartYaw else { return }
                yaw = InteractionMath.gestureYaw(start: start, rotation: Float(gesture.rotation))
                renderer?.yaw = yaw
            case .ended:
                if let start = rotationStartYaw {
                    yaw = InteractionMath.gestureYaw(
                        start: start, rotation: Float(gesture.rotation))
                    renderer?.yaw = yaw
                }
                rotationStartYaw = nil
            case .cancelled, .failed:
                rotationStartYaw = nil
            default: break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
        ) -> Bool {
            // Pause on contact, before a recognizer exceeds its pan/pinch threshold.
            takeTouchControl()
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            func kind(_ recognizer: UIGestureRecognizer) -> String {
                if recognizer is UIPinchGestureRecognizer { return "pinch" }
                if recognizer is UIRotationGestureRecognizer { return "rotation" }
                if recognizer is UIPanGestureRecognizer { return "pan" }
                return "other"
            }
            return InteractionMath.mayRecognizeTogether(
                kind(gestureRecognizer), kind(otherGestureRecognizer))
        }

        func clear() {
            idleMotion.clear(at: session.currentFrame?.timestamp ?? 0)
            handTracker.cancel()
            endHandGrab()
            if let anchor { session.remove(anchor: anchor) }
            if let probe { session.remove(anchor: probe) }
            anchor = nil
            owner.studio.placed = false
            owner.studio.placementHint = nil
            owner.studio.lightPlaced = false
            savedRig = nil
            owner.studio.hasSavedRig = false
            owner.studio.rigLocked = false
            owner.studio.lightLocked = false
            owner.studio.lightHint = "Tap a matte subject or backdrop to aim the light"
            renderer?.lightingRig = nil
            renderer?.studioLight = StudioLightUniforms()
            renderer?.setLightLocked(false)
            probe = nil
            renderer?.placement = nil
            renderer?.anchorID = nil
            renderer?.placementOverride = nil
            dragStart = nil
            pinchStartScale = nil
            rotationStartYaw = nil
            yaw = 0
            scale = 1
            lightDragging = false
            renderer?.yaw = 0
            renderer?.motionOffset = .zero
            renderer?.cinematicStrength = 0
            renderer?.receiverHeight = nil
            renderer?.objectScale = 1
            publish(
                owner.studio.lightTool
                    ? "Tap a matte subject or backdrop to aim the light"
                    : "Scan a surface, then tap to place")
        }
    }
}

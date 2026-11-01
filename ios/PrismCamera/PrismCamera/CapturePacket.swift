import ARKit
import CoreImage
import Metal
import UIKit

// Immutable snapshot of ONE ARFrame plus the uniforms used for its rendered image.
// All slow readback, image encoding, and ZIP work runs off the render/main thread.
final class CapturePacket: @unchecked Sendable {
    let frame: ARFrame
    let uniforms: OpticalUniforms
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let buffer: MTLBuffer
    let wallTime = Date()
    let viewport: CGSize
    let orientation: UIInterfaceOrientation
    let lightingLocked: Bool
    let studioLight: StudioLightUniforms

    init(frame: ARFrame, uniforms: OpticalUniforms, width: Int, height: Int, buffer: MTLBuffer,
         bytesPerRow: Int, viewport: CGSize, orientation: UIInterfaceOrientation, lightingLocked: Bool,
         studioLight: StudioLightUniforms) {
        self.frame = frame; self.uniforms = uniforms
        self.width = width; self.height = height; self.buffer = buffer
        self.bytesPerRow = bytesPerRow; self.viewport = viewport; self.orientation = orientation
        self.lightingLocked = lightingLocked
        self.studioLight = studioLight
    }

    private func packed(_ pixelBuffer: CVPixelBuffer, bytesPerPixel: Int) -> Data {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return Data() }
        let row = CVPixelBufferGetWidth(pixelBuffer) * bytesPerPixel
        var data = Data(capacity: row * CVPixelBufferGetHeight(pixelBuffer))
        for y in 0..<CVPixelBufferGetHeight(pixelBuffer) {
            data.append(base.advanced(by: y * CVPixelBufferGetBytesPerRow(pixelBuffer)).assumingMemoryBound(to: UInt8.self), count: row)
        }
        return data
    }

    func write(imageOnly: Bool = false) throws -> URL {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let renderedData = Data(bytes: buffer.contents(), count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: renderedData as CFData),
              let rendered = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: bytesPerRow, space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let png = UIImage(cgImage: rendered).pngData() else { throw captureError("Could not encode the rendered frame.") }
        if imageOnly {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SpectralPhotos", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let existing = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for old in existing.prefix(max(0, existing.count-9)) { try? FileManager.default.removeItem(at: old) }
            let url = folder.appendingPathComponent("Spectral-\(Int(wallTime.timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).png")
            try png.write(to: url, options: .atomic)
            return url
        }
        let context = CIContext(options: [.cacheIntermediates: false])
        let camera = CIImage(cvPixelBuffer: frame.capturedImage)
        guard let cameraPNG = context.pngRepresentation(of: camera, format: .RGBA8, colorSpace: colorSpace) else {
            throw captureError("Could not encode the camera frame.")
        }
        func matrix(_ value: simd_float4x4) -> [Float] {
            (0..<4).flatMap { c in (0..<4).map { r in value[c][r] } }
        }
        func intrinsics(_ value: simd_float3x3) -> [Float] {
            (0..<3).flatMap { c in (0..<3).map { r in value[c][r] } }
        }
        let imageSize = frame.camera.imageResolution
        var metadata: [String: Any] = [
            "schema": "spectral-studio.capture.v1",
            "surface_fill": ["enabled": studioLight.normalEnabled.w > 0.5,
                "style": LightingStyle(rawValue: Int(studioLight.shapeRight.w))?.title ?? "Soft",
                "profile_axis_and_style": [studioLight.shapeRight.x, studioLight.shapeRight.y, studioLight.shapeRight.z, studioLight.shapeRight.w],
                "source_gain": [studioLight.sourceGain.x, studioLight.sourceGain.y, studioLight.sourceGain.z, studioLight.sourceGain.w],
                "target_radius": [studioLight.targetRadius.x, studioLight.targetRadius.y, studioLight.targetRadius.z, studioLight.targetRadius.w],
                "color_softness": [studioLight.colorSoftness.x, studioLight.colorSoftness.y, studioLight.colorSoftness.z, studioLight.colorSoftness.w],
                "model": "bounded diffuse enhancement of observed RGB; no intrinsic decomposition"],
            "captured_at_utc": ISO8601DateFormatter().string(from: wallTime),
            "ar_frame_timestamp_seconds": frame.timestamp,
            "timestamp_clock": "ARKit monotonic session clock; not Unix epoch",
            "camera_image": ["file": "camera.png", "width": Int(imageSize.width), "height": Int(imageSize.height),
                "orientation": "native ARKit sensor orientation; no display crop or rotation",
                "encoding": "sRGB PNG from capturedImage; processed camera RGB, not sensor RAW"],
            "camera_intrinsics_column_major": intrinsics(frame.camera.intrinsics),
            "camera_to_world_column_major": matrix(frame.camera.transform),
            "tracking_state": String(describing: frame.camera.trackingState),
            "world_convention": "ARKit right-handed meters; camera looks along local -Z",
            "depth_convention": "axial camera depth in meters; not Euclidean ray distance",
            "display": ["width": width, "height": height, "viewport_points": [viewport.width, viewport.height],
                "interface_orientation_raw": orientation.rawValue,
                "view_projection_column_major": matrix(uniforms.viewProjection),
                "view_uv_to_sensor_uv_rows": [[uniforms.imageRow0.x, uniforms.imageRow0.y, uniforms.imageRow0.z],
                                             [uniforms.imageRow1.x, uniforms.imageRow1.y, uniforms.imageRow1.z]]],
            "optics": ["model_to_world_column_major": matrix(uniforms.model),
                "placed": uniforms.flags.x > 0.5, "cauchy_A": uniforms.glass.x, "cauchy_B_um2": uniforms.glass.y,
                "view_wavelengths": Int(uniforms.flags.w), "caustic_wavelengths": 25,
                "room_caustics_enabled": uniforms.glass.w > 0.5,
                "room_lighting_locked": lightingLocked,
                "optical_form": "cut_crystal",
                "illumination_source": "three bright regions fitted from ARKit environment probe; no calibrated lamp positions",
                "virtual_light_enabled": uniforms.light.w > 0,
                "virtual_light_scope": "authored idle-flight crystal reflection lobes only; room caustics remain probe-derived",
                "cinematic_reflection_strength": uniforms.light.w,
                "receiver_plane": [uniforms.receiver.x,uniforms.receiver.y,uniforms.receiver.z,uniforms.receiver.w],
                "virtual_light_direction": [uniforms.light.x, uniforms.light.y, uniforms.light.z],
                "virtual_light_power": uniforms.light.w,
                "comparison_view": uniforms.viewport.z > 0.5, "depth_view": uniforms.viewport.w > 0.5,
                "scene_depth_sampling": "camera-guided inverse-depth reconstruction; exported depth remains raw",
                "edge_sampling": "four subpixel samples at silhouette and face boundaries",
                "optical_resolution": [Int(uniforms.viewport.x), Int(uniforms.viewport.y)]]
        ]
        var files: [(String, Data)] = [("camera.png", cameraPNG), ("render.png", png)]
        if let lighting = frame.lightEstimate {
            metadata["arkit_light_estimate"] = ["ambient_intensity": lighting.ambientIntensity,
                                                "color_temperature_kelvin": lighting.ambientColorTemperature]
        }
        if let depth = frame.sceneDepth {
            let w = CVPixelBufferGetWidth(depth.depthMap), h = CVPixelBufferGetHeight(depth.depthMap)
            let bytes = packed(depth.depthMap, bytesPerPixel: 4)
            guard bytes.count == w*h*4 else { throw captureError("Incomplete depth buffer.") }
            files.append(("depth.f32", bytes))
            var k = frame.camera.intrinsics
            for c in 0..<3 { k[c][0] *= Float(w)/Float(imageSize.width); k[c][1] *= Float(h)/Float(imageSize.height) }
            var depthInfo: [String: Any] = [
                "file": "depth.f32", "width": w, "height": h, "dtype": "little-endian float32",
                "row_stride_bytes": w*4, "source": "ARFrame.sceneDepth (not temporally smoothed)",
                "registration": "aligned with camera.png in native sensor coordinates",
                "intrinsics_column_major": intrinsics(k),
                "validity": "finite positive depth AND confidence >= 1; preserve original samples"
            ]
            if let confidence = depth.confidenceMap {
                let bytes = packed(confidence, bytesPerPixel: 1)
                guard bytes.count == w*h else { throw captureError("Confidence dimensions do not match depth.") }
                files.append(("confidence.u8", bytes))
                depthInfo["confidence"] = ["file": "confidence.u8", "dtype": "uint8", "width": w, "height": h,
                                          "levels": ["0": "low", "1": "medium", "2": "high"]]
                depthInfo["medium_or_high_confidence_fraction"] = Double(bytes.filter { $0 >= 1 }.count)/Double(bytes.count)
            }
            metadata["depth"] = depthInfo
        } else {
            metadata["depth"] = NSNull()
        }
        files.append(("metadata.json", try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])))
        files.append(("README.txt", Data("""
        Spectral Studio synchronized capture
        camera.png: native-orientation processed camera color.
        render.png: the same frame after optical compositing, without app controls.
        depth.f32: optional packed little-endian float32 axial depth in meters.
        confidence.u8: optional ARKit confidence, 0=low, 1=medium, 2=high.
        metadata.json: timestamp, calibration, pose, registration, tracking state, renderer settings.
        All sensor buffers come from ONE retained ARFrame. ARKit supplies registered
        depth; this bundle does not claim hardware exposure synchronization or ground truth.
        Matrices are COLUMN MAJOR. Native sensor images are not display-rotated.
        Camera coordinates look along -Z; convert conventional image-camera axes
        (x right, y down, z forward) to ARKit with diag(1,-1,-1).
        Depth is low resolution: scale intrinsics, do not assume display pixels equal depth pixels.
        Example:
          m=json.load(open("metadata.json"))
          d=np.fromfile("depth.f32",dtype="<f4").reshape(m["depth"]["height"],m["depth"]["width"])
          K=np.array(m["depth"]["intrinsics_column_major"]).reshape(3,3,order="F")
        Captures stay local until you choose a destination in the share sheet.
        """.utf8)))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SpectralCaptures", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Bound local retention. Never enumerate or delete outside this app-owned capture folder.
        let existing = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])
            .filter { $0.pathExtension == "zip" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for old in existing.prefix(max(0, existing.count-4)) { try? FileManager.default.removeItem(at: old) }
        let stamp = Int(wallTime.timeIntervalSince1970)
        let url = folder.appendingPathComponent("Spectral-\(stamp)-\(UUID().uuidString.prefix(6)).zip")
        try StoredZIP.archive(files).write(to: url, options: .atomic)
        return url
    }
}

func captureError(_ text: String) -> NSError {
    NSError(domain: "SpectralCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
}

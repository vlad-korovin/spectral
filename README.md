# PrismEngine 2.1 — image quality and RGB-D integration

The focused Hero Lab renderer and RGB-D integration prototype.

## Install

The **Update ZIP contains only changed/new files**, relative to the PrismEngine root. Extract it into your existing project, retaining assets, include, third_party, and unchanged source. The patch is an alternative, not an additional installation step.

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j 4
ctest --test-dir build --output-on-failure
./build/PrismEngine
```

GLFW remains linked through CMake. The included VS Code configuration supplies desktop build/test/debug tasks and iPhone compile/deploy tasks. See `VSCODE_WORKFLOW.md` for the short workflow. No additional runtime dependency or art asset is required.

## Controls and visual changes

| Control | Action |
|---|---|
| F8 | Cycle Hero render scale: 1× → 1.5× → 2× → 1× |
| F9 | Toggle the labeled synthetic RGB-D occlusion demo |
| F10 | Toggle temporal antialiasing |
| F11 | Cycle MSAA: 2× → 4× → 1× → 2× |
| Space | Pause/resume prism rotation |
| A / D | Rotate manually |
| Q / E | Lower/raise exposure |
| 1–7 | Final / normals / path / dispersion / TIR / LOD / IDs |

Default Hero scale is **1×** with 2× floating-point MSAA, temporal accumulation, and an edge-aware final pass. F8 enables 1.5× or 2× supersampling when quality matters more than preview latency. F11 selects 1×, 2×, or 4× MSAA independently; use 1× for the fastest iteration and 4× for still captures. F10 disables/enables TAA for direct comparison. Equivalent terminal options are `--msaa 1|2|4` and `--no-taa`. Bloom stays at half the window framebuffer resolution and uses two passes.

The concrete albedo, normal, roughness, and HDR environment textures now have mip chains, trilinear minification, and up to 8× anisotropic filtering. The analytic F9 checkerboard uses derivative-based pixel-footprint filtering because a procedural pattern has no stored mip levels. Glass HDR lookups use a small explicit optical footprint to suppress colored texel sparkle. TAA uses an eight-position projection sequence, compact HDR history, neighborhood clamping, highlight rejection, and whole-history rejection on camera jumps.

The F9 synthetic RGB-D fixture is now generated analytically in `camera.frag`. It no longer rebuilds three 640×360 CPU images or uploads them every frame. This keeps the camera-compositing validation path responsive while preserving the recorded RGB-D input path for real captures.

A 512² receiver-space shadow pass uses 32 area-light samples, replacing the previous four distinct silhouettes. Shadow opacity still approximates glass transmission. Caustic power is reduced from 12 to 3; highlight mapping preserves RGB ratios instead of clipping each channel toward white. Unchanged optics reuse the previous caustic/shadow result, including while paused.

Original controls remain: Up/Down change Cauchy A; Right/Left change dispersion B; ]/[ change absorption; +/- change bloom; R resets optical settings/rotation/exposure. I/N select instanced/individual draws; C/V toggle culling; L/K toggle optical LOD. Short function-key taps are now latched correctly.

## RGB-D test and recorded input

Press **F9**, or run:

```sh
./build/PrismEngine --camera-demo
```

## iPhone target

`ios/PrismCamera/PrismCamera.xcodeproj` is a native SwiftUI + ARKit + Metal camera app with one authored flint crystal. Tap a surface to place it, then manipulate it by touch or camera-based hand gestures. Room-derived environment lighting, wavelength-dependent refraction, and LiDAR-aware compositing feed the optical renderer.

For terminal-first Xcode installation, signing, build, device installation, and launch, follow `ios/PrismCamera/TERMINAL_SETUP.md`. Once Xcode and signing exist, `ios/PrismCamera/run-on-device.sh` performs the repeated build/install/launch loop. The mobile app has no package or art-asset dependencies; its optical transport and room-light caustics run in Metal.

The checkerboard and moving orange foreground object are explicit **synthetic test data**, not AI output or live capture. `camera.frag` produces their color and depth analytically without per-frame CPU allocation or texture upload. Foreground depth still exercises prism and incident-haze occlusion. Caustics are added only where observed geometry lies near the configured receiver plane.

For recorded input:

```sh
./build/PrismEngine \
  --camera-rgb color.png \
  --camera-depth depth.pfm \
  --camera-mask confidence.png \
  --camera-intrinsics 640 360 494.546 494.546 320 180 \
  --camera-pose camera-to-world.txt
```

Replace the example calibration with the real values. Depth, mask, and pose are optional; a mask requires depth. RGB alone replaces the background and supplies no occlusion geometry. Without a pose, the existing Hero camera pose is used; this is useful for fixtures, not automatic real-world alignment.

Input conventions:

- Intrinsics: width, height, fx, fy, cx, cy in pixels, upper-left origin. Color/depth/mask must be aligned, undistorted, and identically sized.
- Color: PNG/JPEG or another stb-supported format, decoded from sRGB.
- Depth: single-channel **Pf PFM**, positive optical-axis Z in the **same units as the scene**, not normalized grayscale or Euclidean range. Both byte orders and bottom-to-top PFM rows are supported. Zero/nonfinite values are unknown.
- Optional mask: below 0.5 excludes depth occlusion, at least 0.5 accepts it; RGB remains visible everywhere.
- Pose: 16 whitespace-separated column-major camera-to-world values. OpenGL camera axes are +X right, +Y up, −Z forward. OpenCV-style extrinsics require the appropriate Y/Z conversion and inversion.
- The optical receiver remains the Hero plane at y=−0.85. Recorded geometry must be aligned to it to receive caustics. No plane detection or pose estimation runs automatically.

The pinhole convention follows the [OpenCV calibration documentation](https://docs.opencv.org/4.x/d9/d0c/group__calib3d.html), with explicit conversion to OpenGL camera axes.

## CV / AI boundary

CameraFrame.hpp defines synchronized RGB, depth, mask, intrinsics, rigid pose, sequence number, and timestamp. PrismEngineNative::frameProvider accepts frames from a producer; HeroRenderer::setCameraFrame validates and uploads real or recorded frames on the rendering thread. Textures update in place while dimensions are unchanged. A capture/CV worker should deliver the latest complete synchronized frame. Match the window aspect ratio to its calibration, as the recorded-input and demo paths do.

This remains the desktop integration boundary for tracked pose, neural depth, and segmentation. The iPhone target now owns live camera capture, AR pose, light estimation, and supported hardware occlusion through ARKit. **Neural inference, calibration estimation, and neural temporal reconstruction are not implemented in this increment.** Temporal reconstruction additionally requires motion vectors, history rejection, and a chosen model/runtime.

## Validation and limits

The Release build and all three test suites cover spectral transport; camera geometry/frame validation/PFM decoding; and compilation/linking of the GLSL programs. Tests cover off-center projection, invalid input rejection, PFM byte/row order, moving nearer geometry, and the single-object Hero scene.

Native desktop GPU checks successfully rendered Hero and the synthetic RGB-D demo; foreground depth occlusion was inspected. After moving the F9 fixture to the GPU and returning the default to 1×, spot readings were roughly 43 FPS for Hero and 45 FPS for F9 in the test window. These are observations at one window size, **not a sustained benchmark or guarantee**. Existing GPU pass timers omit receiver/caustic/shadow work.

This remains focused raster optical transport, not path tracing. Caustics use 31 wavelengths; glass view rays use three display-channel wavelengths. The prism is sharp-edged, the optical receiver planar, and offscreen refraction falls back to HDRI. Partial reflection branches are discarded. Camera depth currently occludes the image; it does not redirect spectral rays through arbitrary reconstructed meshes. The synthetic test colors are deliberately simple.

Repeatable local checks:

```sh
./build/PrismEngine --frames 5 --time 0 --render-scale 1.5 --capture hero.ppm
./build/PrismEngine --camera-demo --frames 5 --time 0 --capture depth-demo.ppm
```

The original HDRI and concrete asset paths are unchanged. The update ZIP does not duplicate those files.

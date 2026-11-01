# Spectral Optics Lab — Spectacles development build

The iPhone app remains in `../ios/PrismCamera`, restored to the state before the abandoned product-photography workflow. This folder is a separate Lens Studio project. It does not change the iPhone build.

**Status: the project opens and runs in Lens Studio; this update passes the portable tests and Lens Studio TypeScript declarations. It is not published.** A host test is not a Spectacles hardware test, so the in-Lens diagnostics are the source for device FPS and optical-update cost.

## Open and test

Download the **Spectacles-compatible** Lens Studio build from [Snap](https://ar.snap.com/spectacles), install it, then run:

```sh
cd ~/Coding/PrismEngine/spectacles
./open-in-lens-studio.sh
```

Open `OpticsLab/OpticsLab.esproj`. Its native scene and full SIK, Sync Kit, UI Kit and LSTween package files are included; they are not Git LFS placeholders. Package hashes and the upstream tree are recorded in `OpticsLab/PROVENANCE.json`; Snap's attribution/license is included. The starter is the official `Spectacles Sync Kit` sample, which predates the upstream repository's deprecation. Use a compatible editor before upgrading all packages together.

1. Let the editor import the scripts/packages. Open **Window → TypeScript Status**. Resolve any editor/API compatibility errors before treating the Lens as runnable.
2. Set the preview device override to **Spectacles**. Use the starter's **Solo** path for local development. Its interactive environment supplies simulated world data; webcam mode supplies a different input. Neither proves hardware tracking or colocation.
3. The crystal is no longer a fixed scene overlay. Point into the room and pinch once to commit a **world-space pose** 75 cm along the SIK ray, matching the iOS app's default Space placement. The hidden `surfacePlacement` developer input enables a World Query surface hit instead, matching iOS's optional Surface mode. The crystal and light stay hidden before that placement. After placement, pinch and move your hand in X/Y/Z; distance-scaled Z stretch makes depth placement practical. Use two hands to rotate and uniformly scale it. Direct pinch, indirect ray and direct poke are selected automatically by SIK. Room depth now occludes both the crystal and the teaching rays. After three untouched seconds it uses the same quintic lift, bounded drift, accelerating yaw and warm-key/cool-rim idle blend as iOS. Grabbing pauses that motion without a release jump. The separate source is initialized relative to the committed crystal pose and can then be moved and rotated independently, so lighting reacts continuously rather than switching between canned animations.
   For editor testing, use **Interactive Preview**. **No modifier key is required:** left-click and hold directly on the crystal, drag it, then release. An empty-space click performs initial placement. `Cmd` is not a manipulation gesture. Move the simulated viewer with **W/A/S/D**, **Space** (up), and **Ctrl** (down). The supplied MouseInteractor has SIK's **Move In Depth** test enabled with a 12 cm range; while the button is held, SIK automatically oscillates the simulated pointer along its ray. That is a synthetic depth test, not precise mouse-controlled Z placement. Interactive Preview supplies one mouse interactor, so it cannot faithfully reproduce the two simultaneous interactors required for two-hand rotation and scale; validate those gestures on Spectacles. **Webcam Preview is useful for checking whether Lens Studio's hand model sees a hand, but it is not a faithful simulator of Spectacles' SIK targeting ray, direct-pinch depth, or two-hand manipulation.** The diagnostics line reports `L/R --`, `tracked`, or `pinch`; validate the complete gesture set on connected Spectacles.
4. Use the world controls to cycle **Material**, **Lighting** and **Explain**. Lighting matches the iPhone profiles: Soft, Spot, Strip, Window and Halo. Each profile is a bounded area-source sample pattern; every source sample traces all 31 wavelengths through the current glass transform.
5. In `Lesson controller → VoiceControl`, enable `listenOnDevice` **on Spectacles**. Speech is off by default because ASR is Spectacles-only. Say exact commands such as “Spectral diamond”, “Spectral soft light”, “Spectral halo light”, “Spectral blue light”, “Spectral explain”, or “Spectral hide equations”. Partial transcripts, negations and casual mentions do not trigger changes. Use the spatial controls when speech is unavailable.
6. Test two devices through the starter's multiplayer start flow. Finish shared-space mapping/relocalization first. Crystal and light have separate SIK manipulation state; material/light/lesson settings are separate Sync Kit properties. The duplicated old `SyncTransform` components are disabled so two systems do not write the same transform. Verify concurrent grabbing, disconnect/rejoin and late joining on hardware.

Host tests, independent of Lens Studio:

```sh
npm ci --ignore-scripts
npm test
npm run bench
```

The benchmark measures only 31 CPU ray paths on the host. It does **not** measure wearable FPS, GPU work, SIK, network traffic, world query cost or thermals.

## What this step contains

- Portable convex crystal/prism intersection and bounded Snell/TIR tracing. The crystal's 18 half-spaces match the frozen iPhone geometry; the displayed crystal mesh is generated from those half-spaces.
- 31 samples over 420–680 nm, per-interface unpolarized Fresnel transmission and four sourced Sellmeier material presets. Sapphire explicitly uses the ordinary-ray approximation. Water is an ideal fixed boundary, not a fluid/container simulation.
- Five energy-normalized area-light profiles shared conceptually with iOS. Spot traces 31 paths; Soft, Strip and Window trace 155; Halo traces 248. The source pose and aperture orientation are live inputs, so moving or rotating either object changes the computed entry/exit faces and caustic.
- Live incident, refracted and critical angles plus the equations calculated for the selected representative wavelength. Lines show the actual computed path, rather than a separate decorative animation. Spectral RGB uses the iPhone's positive-primary approximation, not calibrated XYZ.
- A 256×1 procedural colour texture and two batched meshes hold all teaching rays and additive receiver patches. Tracing updates at most 20 Hz; unchanged transforms sleep. One World Query request may be in flight, at most 5 Hz. Missing/stale results hide receiver patches.
- The in-world diagnostics report display FPS, measured optical rebuild p50/p95 CPU time, optical update rate, spectral path count, generated ray vertices, accepted receiver hits and actual room-query callback rate. Optical timing excludes Lens rendering, SIK and asynchronous room-query work; FPS covers the running Lens update loop.
- The World Query hit supplies a **local planar approximation**, limited to a 20 cm footprint around that hit. It is not a full world-mesh caustic integrator. Visible light lines are explanatory overlays, not simulated atmospheric scattering.
- SIK manipulation, spatial controls, Spectacles ASR adapter and Sync Kit shared settings/scene configuration. These require editor/device verification.
- **Native World Mesh depth occlusion.** A `World Mesh.worldmesh` asset and "World Mesh Occlusion" scene object use the WorldRenderObjectProvider to render real geometry with a depth-only material, masking the transparent glass and additive rays behind real surfaces. Crystal and ray depth testing are enabled by default; the previous stable-visibility override that made them read as an overlay is disabled. `SpectralLab.room()` enables tracking and configures the provider at runtime. Classification is set to `None` (Spectacles has no LiDAR).
- **Dynamic environment from device camera.** The Envmap LightSource's `UseEnvMapFromCamera` flag is set `true` with `DynamicEnvInputTexture` wired to the Device Camera Texture asset, replacing the baked Echopark.hdr with live camera-derived illumination when available.

## Remaining release gates

1. **Latest-edit preview and visual review.** Run the project after every pull so Lens Studio reimports changed TypeScript and scene bindings. Verify picking, colour and both-eye rendering. Current glass is a transparent PBR preview surface, not a port of the Metal screen-space refraction renderer.
2. **Room rendering.** ✅ *Configured.* The native World Mesh is wired as a depth-only occlusion visual (WorldMesh_Occlusion.mat: DepthWrite true, ColorMask off, BlendMode Disabled) so real surfaces hide the glass and rays. Initial placement is a committed world pose from the active SIK ray; optional Surface mode uses World Query at its native 5 Hz. A dynamic environment map is configured: the Envmap LightSource has `UseEnvMapFromCamera: true` with `DynamicEnvInputTexture` set to the Device Camera Texture; the baked Echopark.hdr remains as fallback. These features still require Spectacles hardware validation. World Query alone cannot handle a fast moving hand.
3. **Connected hardware session.** Spatial relocalization and shared ownership require two devices. Packet rates, reconnect behavior and manipulation contention have not been measured. SDK synchronization is not a cross-platform iPhone/Spectacles session.
4. **Capture and publishing.** Video scripts, capture plans, claim checks and performance logs now live in the separate `~/Coding/SpectralVideo` workspace. Replace all pending evidence in `docs/RELEASE_CHECKLIST.md`, then submit from an authenticated Snap creator account. No videos, public Lens URL, App Store release or usage counts are claimed by this step.

Spectacles uses an additive optical see-through display. Virtual geometry cannot physically darken the floor or bend photons arriving from the room. A world-depth occlusion mask hides the virtual object behind the room; it does not hide the room behind virtual glass. Keep that distinction visible in the portfolio. [Snap's display guidance](https://developers.snap.com/spectacles/best-practices/design-for-spectacles/ui-design).

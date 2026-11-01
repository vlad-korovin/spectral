# Spectral — Practical Light Studio

Spectral asks a practical photography question: what if lighting could stay in
the scene, with the directness and credibility of a real light setup, while
gaining the flexibility of a visual tool? A depth-aware fill tool now lets you aim, widen and tint a local enhancement
on a real subject or backdrop before capture. The crystal remains a separate
optical instrument using the room environment.

The mobile product has one authored object: a faceted flint crystal. Its visible
refraction and receiver caustics use the same closed 18-plane solid, Cauchy
dispersion, Snell refraction, Fresnel loss, absorption, and bounded internal
reflection. Bright regions of the ARKit environment probe provide room-derived
lighting, without a synthetic sun. Idle flight optionally layers authored studio
reflections onto the crystal; these do not create additional room caustic sources. The separate Light tool is an explicitly
user-directed computational fill; it does not physically change the room.

## Run on iPhone

Use the VS Code task **iPhone: Build + Install + Launch**, or:

```bash
cd ~/Coding/PrismEngine
DEVELOPMENT_TEAM="YOURTEAMID" \
PRODUCT_BUNDLE_IDENTIFIER="com.example.spectral" \
./ios/PrismCamera/run-on-device.sh "Your iPhone"
```

The installer validates the Metal source on the Mac, builds Release, installs,
and launches. See `TERMINAL_SETUP.md` for first-time Xcode and signing setup.

## Experience

The camera opens on **Crystal**, with **Space** placement by default. Tap anywhere
to summon it about 75 cm away. Surface placement remains available inside the
ellipsis menu → Your crystal → Place in. It is not shown over the camera.

The single creative tray contains Crystal/Light tools and one contextual prompt.
Light has five illustrated aperture buttons: Soft, Spot, Strip, Window, Halo.
Strength appears after aiming the light. Advanced width, direction, warmth,
Remember/Recall and room-light controls live in the ellipsis menu.

- **Automatic interaction:** there is no Touch/Hands selector and no depth slider.
  Drag, pinch and twist on screen at any time. Screen touch releases a hand grab
  first and rejects stale Vision results; fresh hand input resumes after a short
  touch-priority interval.
- **Catch the crystal:** bring your hand over it, pinch to grab, lift or sweep to
  move, and open to release. With reliable palm depth, moving the hand nearer or
  farther also moves the crystal along the room's third dimension. A small cursor
  shows recognition and turns mint on acquisition. Merely seeing a hand pauses
  idle flight; it does not automatically grab an object.
- **Depth fallback:** a grab without reliable palm depth uses a fixed view-facing
  plane, so upward and sideways movement still work. The source is fixed for that
  grab. A depth-based grab holds still if depth becomes unreliable, rather than
  switching to a background surface. Open and re-grab if needed.
- **Idle flight:** untouched for three seconds, the crystal rises and turns with
  cinematic reflections. Rest eases it back to its placement anchor; Float enables
  idle flight again. These actions are in the creative tray. Reduce Motion pauses
  automatic animation.
- **Light:** tap a matte subject to aim. Drag to move the target, pinch to widen,
  and twist the source. The aperture thumbnails select distinct light profiles.
- **Compare:** hold to see the camera image. **Hold:** pauses idle motion and fixes
  the fill target against gesture changes. Direct crystal manipulation remains
  available. The shutter exports a clean display-resolution PNG with 31 crystal
  wavelengths, independent of live quality; it is not sensor RAW.
- **Menu:** placement, recognition enablement, idle/cinematic preferences, room
  caustics/lighting lock, quality and setup memory. Capture Lab is collapsed by
  default. Start a fresh scene resets the instruments.

Hand inference is throttled to 4 Hz when searching and up to 12 Hz when a hand is
visible, with one request in flight. It pauses for touch priority, Light, menus,
comparison, capture and diagnostics. There is a hidden recognition switch for
comparison testing; normal use requires no mode switching.

## Current boundaries

The fill estimates surface orientation from camera-guided LiDAR depth and adds
a bounded diffuse contribution to existing image color. It preserves highlight
headroom but cannot recover albedo, remove baked-in shadows, illuminate black
image detail, or reconstruct off-screen occluders. Use controlled matte subjects
first. No subject segmentation, neural relighting or camera exposure lock is
implemented.

Room lighting is image-based illumination, not calibrated lamp detection or
full-spectrum sensing. Screen-space refraction cannot reconstruct unseen surfaces.
LiDAR depth remains coarse around thin and reflective objects. Vision landmarks
plus a small confident LiDAR palm patch estimate a 3D grip point; this is not a
tracked 3D hand skeleton or a segmented hand-depth map. Palm orientation, depth
holes and nearby background can reduce reliability. Conservative rejection may
require opening and re-grabbing; touch remains available.

The intended quality target is iPhone 16 Pro Max and newer. Performance and
appearance still require measurement on that hardware. The iPhone 12 Pro Max is
useful for compatibility testing, but its hand-recognition frame rate is not the target.
Space placement does not imply collision avoidance. Real depth occludes the glass
where supported, but it does not stop you dragging through objects. Caustics still
need a detected horizontal receiver below the crystal; unknown geometry does not
receive an invented projection.

The current product milestone is a still-photography instrument. Exposure lock,
subject-aware depth/segmentation, authored lighting compositions and a short-video
capture path are the next parts of the photography workflow; they are described
in `PRACTICAL_LIGHT_STUDIO.md`.

## Validation

```bash
python3 ios/PrismCamera/tests/transport_tests.py
python3 ios/PrismCamera/tests/studio_tests.py
python3 ios/PrismCamera/tests/capture_tests.py
python3 ios/PrismCamera/tests/lighting_tests.py
xcrun swift ios/PrismCamera/tests/validate-metal.swift \
  ios/PrismCamera/PrismCamera/Optics.metal
```

Host tests cover crystal transport, internal reflection, spectral normalization,
gesture state, image orientation, capture integrity, and depth reconstruction.
The final command requires a Metal-capable Mac and checks runtime shader pipelines
and offscreen output for all five light modifiers. A SKIP is not a GPU validation pass.
See `PRACTICAL_LIGHT_STUDIO.md` for implemented scope and device profiling.

See `ROOM_LIGHT_AND_CRYSTAL.md` for room-light fitting and device acceptance tests.

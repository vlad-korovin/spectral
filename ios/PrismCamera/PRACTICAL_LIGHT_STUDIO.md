# Spectral: depth-aware photographic fill

## Implemented milestone

The Light tool works directly on measured real surfaces, independently of the
crystal. Aim at a matte subject or backdrop, drag the target, pinch its width and
twist the source around it. Fill controls intensity; Studio provides warmth and
direction. Hold composition blocks touch changes. Remember/Recall retains one
setup in the current AR session only; resetting tracking clears it.

The shader reconstructs positions from axial LiDAR depth, estimates normals with
one-sided depth derivatives, rejects uncertain depth edges, applies diffuse
response and bounded distance falloff, and feathers the illuminated region.
Six screen-space visibility probes suppress some visible occluders. Highlight
headroom rolls off the added contribution without changing the zero-fill image.
It is an enhancement of observed color, not recovered material reflectance or
physically complete relighting. Missing depth disables the effect.

The crystal retains environment reflections, spectral refraction and room-derived
caustics. Its room-light lock is separate from holding the fill composition.
There is no synthetic sun. The fill is a deliberate virtual source controlled by
the photographer; it does not affect physical room light or other cameras.

The shutter uses native display dimensions and 31 crystal wavelengths even when
live preview uses Balanced. It exports a clean PNG, not sensor-resolution RAW.
Capture Lab includes fill parameters with calibrated camera/depth data. It does
not include the environment cube and therefore is not an exact rendering replay.

## Lighting modifiers and cinematic motion

Soft retains the original diffuse pool. Four additional profiles share the same
pass: Spot (feathered cone), Strip (slender vertical wash), Window (four soft panes)
and Halo (backdrop ring). The directional profiles project an aperture through
the source onto measured geometry, so oblique surfaces stretch the pattern. Their
world-space basis remains stable while the camera moves. The footprint is locally
bounded to avoid uncontrolled enhancement of distant surfaces. Integrated energy
varies with aperture shape; Fill is an artistic gain, not calibrated lamp power.
Halo is not a person-aware rim-light effect. Warmth and source direction remain
independent controls. Remember/Recall now includes the chosen modifier.

Idle flight starts three seconds after interaction. Over about 3.5 seconds it
rises to a bounded 12 cm hover with a small lateral orbit and vertical bob, while
easing toward 4.3 degrees per second. A single visible pose drives optical entry/
exit geometry, caustics, touch tests and capture. Pausing preserves the offset;
resuming interpolates from that pose, so repeated touches do not stack altitude.
Rest eases the offset and cinematic treatment back to zero in 1.2 seconds, then
leaves idle flight disabled. The Idle flight toggle itself freezes the pose.

During the rise, optional warm key and cool rim reflection lobes fade onto the
crystal and slightly strengthen the existing highlight bloom. These are authored
virtual studio reflections, not measured real lamps. The room environment and
user fill controls remain unchanged. Their axis is fixed in world space at
placement, so moving the camera does not drag the highlight setup around. The
capture metadata records the cinematic axis and blend.

The redesigned camera has a single translucent creative tray, illustrated light
apertures, a compact header and contextual grab feedback. Advanced settings are
behind an ellipsis. Space is the default and places at a comfortable 75 cm; the
Surface/Space option lives only in that menu. The depth slider and mode selectors
have been removed, including their underlying interaction state.

Touch and hands share the visible object pose. Any screen contact releases the
hand grip before touch recognition, preserves the object transform and invalidates
in-flight Vision results. A 0.4-second grace window and sample timestamps keep old
observations from reclaiming control. Merely seeing a hand pauses idle flight;
a pinch over the expanded glass hit box is required to acquire the object.

A 3×3 confident LiDAR patch near the observed palm is accepted only if at least
five valid depths form a compact layer and the depth-scaled palm size is plausible.
The corresponding camera-space point is transformed using that same AR frame.
The crystal retains its initial offset from the hand, so acquisition does not snap.
Lifting, sweeping and approaching the phone can then move all three world axes.
When depth is unavailable at acquisition, a view-facing plane provides up/down
and lateral motion. The tracking source does not change during a grab. Lost depth
holds the pose; stale observations and large jumps are rejected. This is an
approximate palm grip, not a 3D skeleton, segmentation model or guaranteed hand
surface association. Low-confidence cases may need an open/re-grab gesture.

Touch dragging still uses a fixed acquisition plane; pinch sizes and twist rotates.
Surface placement remains available but does not limit hand movement to the floor.
Camera motion cannot change the captured touch plane or hand/object grip offset.

A detected receiver's world height is separate from the crystal's pose. It stays
on the table while the glass flies. Space mode searches for a detected horizontal
surface below a committed position; if none exists, caustic computation is skipped.
This is not scene-mesh light transport or collision avoidance. A free object may
be dragged into real geometry; depth affects rendering occlusion only.

Touch pauses before recognizer thresholds. Hand presence, capture, Hold composition,
diagnostics, settings, app inactivity, tracking loss and Reduce Motion pause
automatic motion. Long stalls restart the delay without catching up. Rest is an
explicit return to the placement anchor, not an automatic physical landing search;
in Space that anchor may be in the air. Reduce Motion makes explicit Rest instant.

## Performance changes

- Light modifiers use analytic math in the existing finish pass, with early
  rejection of unlit pixels before depth-normal and visibility calculations.
  They add no textures, render targets, shadow maps or inference work.
- Idle motion evaluates a bounded analytic pose once per AR frame and reuses existing optical
  transport. It may prevent static-pose reuse; motion is not a free GPU effect.
  Cinematic reflections add two broad analytic lobes at glass hits and reuse the
  existing bloom samples, with no extra pass or textures. Space mode skips caustic
  computation when no real receiver is known.
- One nonblocking GPU submission in flight bounds stale-frame latency. Busy ticks
  are dropped rather than queued; this is not a guarantee of higher throughput.
- Depth reconstruction is reused for repeat display ticks of the same sensor
  frame. The guide retains full camera resolution.
- Locked room-light fitting is reused until unlocked or GPU state is invalidated.
- Crystal plane intersections use fixed eightfold symmetry constants instead of
  repeated trigonometry inside every spectral bounce.
- Light-only, Compare and depth views skip the optical render pass. Light-only
  compositing does not sample the optical layer. Disabled/zero fill with no
  crystal skips depth reconstruction too.
- Spectral tables, light buffers, caustic buffers and render targets are reused.
  A separate full-resolution still target avoids resizing the preview target.
- Automatic hand search runs at 4 Hz, increasing to at most 12 Hz for visible
  hands. One request is in flight; Vision resources stay warm. Touch priority,
  Light, menus, comparison/capture and diagnostics suspend submissions. Only a
  tiny palm depth patch is read on the worker after a hand has been recognized.
- Hand smoothing uses elapsed sample time rather than a fixed per-event blend.
- Capture encoding runs off the main thread after GPU completion. A still can
  take longer than a preview frame; capture currently repeats the final composite
  for export, which remains a possible future optimisation.

The native-resolution camera and fill are preserved. These changes remove unused
work; no device speedup or thermal result is claimed without measurement.

## Device acceptance and profiling

Install Release using run-on-device.sh. Keep the phone still in a reproducible,
well-lit matte scene, disable screen recording, and open Capture Lab diagnostics.
Use the same brightness and power state for each run. Record device, OS, quality,
thermal state and scene; compare against the previous build under those conditions.

Warm up for 30 seconds, then observe each case for 60 seconds:

1. Camera baseline: no crystal, fill disabled.
2. Fill alone: same target and radius, Fill 0.7, then Fill 0.
3. Crystal alone: room caustics enabled, fill disabled.
4. Both tools, then lock the room environment and repeat.
5. Automatic hand search with no hand, then active grabs. Use the hidden recognition
   switch to compare against a renderer-only baseline; record both costs.

Record displayed fps, GPU milliseconds, GPU p95 and skipped busy ticks. Reported
p95 covers completed GPU work in each roughly one-second reporting window; it is
not end-to-end latency or a full-session percentile. A 60 fps target has a 16.7 ms
whole-frame budget; GPU time below that alone does not prove 60 fps. Use Xcode's
Metal System Trace for CPU/GPU scheduling and allocation evidence when available.

Check these behaviours alongside speed:

- Compare all five modifiers on one flat matte backdrop. Check smooth edges,
  distinct shapes and stable world-space placement while moving the camera.
- Wait three seconds for idle flight. Touch, drag, pinch and twist without snapping;
  hold a finger still for ten seconds to confirm motion remains paused.
- Repeatedly pause/resume the hover; altitude must not accumulate. Rest should
  ease back to the anchor while reflections return to the room-only look.
- Place in Space without a detected plane, drag vertically and horizontally, and
  grab and lift with a visible hand, then move it nearer/farther with reliable depth.
  Check acquisition and release for jumps. Touch during a hand grab: it must take
  over immediately, with no delayed Vision correction. Confirm pinch still sizes
  and twist still rotates; return to hands without opening settings.
- Place on a table and let the object rise: receiver caustics must remain on the
  table, and missing receivers must not create a floating patch of light.
- Verify the pose stays fixed during capture/Hands/settings/Reduce Motion and that
  returning after an interruption does not catch up skipped animation.
- Zero fill and Compare match the unmodified camera. Missing depth adds no fill.
- A matte plane brightens smoothly; silhouettes do not gain a bright fringe.
- Ten drag-to-pinch/twist transitions cause no positional snap.
- Hold blocks gestures; Recall restores the target and source settings.
- Camera movement keeps the fill at the same world target.
- A shutter shot omits controls/diagnostics and uses display-size output.
- After several minutes, repeat measurements and note thermal degradation.

## Validation of this change

Host transport, interaction, capture and fill-headroom tests pass, including all
five production lighting profiles (bounds, symmetry, continuity) and idle-motion
frame-rate independence, the three-second delay, bounded lift, pause/resume,
landing and long-stall handling. Automatic ownership, stale-observation rejection,
palm-depth discontinuities, 3D grip offsets, time-based smoothing and free-space
ray/plane tests also pass. Swift code has
been typechecked for iOS, and a code-only unsigned Release device build passes.
This environment cannot validate the asset-catalog build or access a Metal device;
the GPU shader/offscreen test reports SKIP here. Run it on the development Mac
before installation, then run the physical-device checks above. Performance and
visual quality on iPhone 16 Pro Max or newer remain unmeasured.

## Boundaries and next evidence

Coarse/noisy LiDAR, glossy/transparent subjects, thin edges, existing shadows and
unseen surfaces constrain quality. Exposure and white balance can still change.
There is no person mask, intrinsic decomposition, neural relighting, persistent
world-map rig storage or finished video capture. Controlled matte still-life
photography is the intended first evaluation, not universal studio replacement.

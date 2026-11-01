# Room light and cut crystal

The sun marker, light-steering mode, synthetic spotlight, alternate prism, and material selector are removed. **Touch** and **Hands** manipulate one authored crystal. Touch uses one finger to move and a simultaneous two-finger pinch/twist to size and aim it.

The touch transform is anchored at gesture begin rather than accumulated from
per-frame deltas. A one-finger drag interrupted by the second finger commits its
latest position, preventing the mode-transition snap that previously made
pinch-and-twist unreliable.

## Play with the room

Place it on a matte tabletop near a window or lamp. Move the phone around the object so ARKit can collect the surrounding environment. Rotate the crystal and move around it: visible camera imagery and captured room reflections feed wavelength-dependent entry/exit paths. The crystal has sixteen sloping facets plus two truncated ends; it shares the exact same solid between rendering and forward light transport.

**Room-light caustics** fits up to three bright upper-hemisphere regions from the ARKit environment probe. Their directions, colors, angular spreads and relative energies drive spectral receiver contributions. No source is created while the probe is missing or uniform. Reflections/refractions continue in diffuse lighting, but sharp colorful caustics may be absent. Move a real lamp or change the room lighting to explore the response as the probe updates.

**Lock light setup** takes a GPU-side copy of every environment-cube face and mip
level. The live camera and crystal transform continue updating, while reflections,
refraction and caustic fitting use the frozen room-light state. This provides
repeatable takes without a CPU readback. Unlock after changing a lamp or location.

This is image-based illumination, not calibrated lamp recognition, exact real-world irradiance, full-spectrum sensing, or reconstructed lamp positions. A bright window and a bright reflective object can be ambiguous. The camera/probe may clip real light intensity and update with latency; effects on surfaces are visual composites. Natural-room illumination does not mean arbitrary room lighting is already physically reconstructed.

## Easier grabbing

Select Hands and bring thumb and index fingertips over the object. Two stable relaxed-pinch observations can acquire; no exaggerated open-hand reset is needed. An already-pinched hand may move onto the object to grab it. Open to release. The expanded target and wider opening/closing thresholds tolerate more variation. A missed observation freezes the pose briefly (up to about 0.4 seconds), then releases; it never extrapolates a lost hand. Reset/mode changes invalidate pending hand requests.

Vision now reuses its request rather than rebuilding it per inference. The optional hand mode runs at most twelve requests per second, with one in flight. Hand movement remains constrained to the support plane, not full 3D tracking or lifting. The iPhone 12 Pro Max's measured 12 FPS is not a performance target or evidence of newer-device speed.

## Quality and validation

Studio quality uses 31 view wavelengths at the existing 2200-pixel maximum optical height. Balanced uses 13. Caustics use 25 wavelengths. The intended high-quality device target is iPhone 16 Pro Max and newer; this target has not yet been benchmarked on that hardware. Hands and room caustics remain independently selectable for measurement.

Host tests exercise the closed crystal's refraction/internal reflection/energy bounds, relaxed pinch hysteresis, image orientation, and normalized spectral tables. The iPhone Release build was checked. The runtime Metal validator includes missing/uniform-environment rejection and a bright-region lighting test; GPU execution is unavailable in the Codex sandbox, so the existing installer runs it on the developer Mac.

## Acceptance pass

1. Verify no sun or manual light control appears. In an evenly lit room, do not expect an invented sharp rainbow.
2. Scan a window-lit room, place the crystal on a matte table, then rotate it. Check reflections, transmitted detail and orientation-dependent dispersion.
3. Try ten grabs, including pinching slightly outside then entering the object, brief fingertip occlusion and a full tracking loss. Record successful acquisitions and any jumps.
4. Measure Balanced/Studio quality with Hands off/on separately on the intended newer device. Capture a synchronized dataset for remaining artifacts.

The source metadata now identifies the optical form and room-based illumination. The environment cube itself is not yet included in exports, so existing capture ZIPs cannot exactly replay the fitted room lighting.

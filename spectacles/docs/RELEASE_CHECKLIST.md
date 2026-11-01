# Release evidence — do not mark pending features complete

| Gate | Current evidence |
|---|---|
| Restored iPhone Release code build | PASS, unsigned iOS target; asset catalog excluded in sandbox |
| Existing iPhone interaction/archive tests | PASS |
| Portable TypeScript optical/scene tests | PASS, 15 numerical and serialized-binding checks |
| Lens adapter syntax | PASS, full project type-check against StudioLib.d.ts and included SIK/Sync Kit packages |
| Lens Studio import + full SDK compile | PASS, Lens Studio 5.15.4; latest TypeScript compilation succeeded after reload |
| Lens visual review, stereo/culling/materials | PARTIAL — branded Spectral start shell and live scene boot reviewed; stereo hardware review pending |
| Webcam/interactive preview gesture exercise | USER PASS on prior build; repeat for five new light profiles |
| Device ASR, interruption and permission behavior | PENDING |
| Dynamic room environment reflections | CONFIGURED — device verification pending |
| Native world-mesh/depth and hand occlusion | CONFIGURED — device verification pending |
| World Query local-plane patch accuracy | CODE ONLY — device verification pending |
| Shared colocation, ownership, late join/reconnect | CONFIGURED/CODE ONLY — two-device verification pending |
| Five-minute thermal/frame-time/network measurements | PENDING |
| Two real 90-second videos | SHOT LISTS ONLY |
| Public Lens submission/approved URL | NOT SUBMITTED |
| iPhone App Store publication | NOT SUBMITTED; development install is not publication |
| Learner/teacher value validation | NOT RUN |

## Editor and hardware acceptance

- Reopen the supplied project after changes and confirm `TypeScript compilation succeeded!` in Lens Studio. Check every generated TypeScript input binding and material import; a green host test alone is not an SDK compile.
- Move/rotate/scale glass and source independently. Confirm 3D normals/labels follow the optical faces. Release and reacquire both hands without movement jumps; test direct poke separately from pinch manipulation.
- Loss of tracking, missing room hits and a moved object must clear stale receiver patches. Test floor and vertical wall hits; keep the local-plane approximation clear.
- For room occlusion, test a static object and fast hand separately. World Query's documented 5 Hz depth updates are not fast hand occlusion.
- Test two people manipulating different controls, then contention for the same object. Verify location-relative transforms after relocalization and late joining. Inspect actual sends/sec; built-in SIK syncing is not capped by our optical update limiter.
- Test ASR without network, denied microphone permission and interrupted sessions. Use spatial controls as the fallback. Do not log transcripts.
- Measure end-to-end frame time and tracking latency on actual devices; record p50/p95 and thermal conditions. The host benchmark excludes rendering, tracking, query and network work.

## Publication

The user has requested publication, but this development build is not ready to submit. Finish the gates above, record the true demo, create the 3:4 Spectacles preview, then use Lens Studio's Publish flow from the intended Snap creator account. Supply accurate feature/privacy details and wait for moderation. Record the real Lens URL and review date here; do not fabricate a link or usage count.

[Snap publishing guide](https://developers.snap.com/spectacles/get-started/start-building/publishing-lens) · [Connected Lenses scope](https://developers.snap.com/spectacles/about-spectacles-features/connected-lenses/overview) · [World Query limits](https://developers.snap.com/spectacles/about-spectacles-features/apis/world-query) · [ASR availability](https://developers.snap.com/spectacles/about-spectacles-features/apis/asr-module)

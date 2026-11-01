# PrismEngine entirely from VS Code

Open `/path/to/PrismEngine` as the VS Code folder. Use **Terminal → Run Task** or `⇧⌘P` → **Tasks: Run Task**.

## Everyday desktop loop

- **Desktop: Run** builds Release and launches Hero Lab.
- **Desktop: Run Fast Camera** launches F9 with 1× MSAA and TAA disabled for the fastest iteration.
- **Desktop: Test** rebuilds and runs all C++, camera, optics, and shader checks.
- Press `F10` in the app to compare TAA and `F11` to cycle 1×/2×/4× MSAA.
- The Run and Debug sidebar contains **PrismEngine: Hero** and **PrismEngine: F9 Camera Demo** for LLDB breakpoints.

## iPhone loop

Run these VS Code tasks in order:

1. **iPhone: Diagnose Setup** — confirms full Xcode, local signing identities, and connected devices.
2. **iPhone: Build Simulator (No Signing)** — compile-checks all Swift, ARKit, and RealityKit code without a certificate.
3. **iPhone: List Devices** — shows the exact device name.
4. **iPhone: Build + Install + Launch** — prompts for the device name, Personal Team ID, and a unique bundle identifier, then builds, installs, and launches on the phone.

**Verify: Desktop + iPhone Compile** runs the complete desktop test suite followed by the unsigned iPhone compile check.

## One-time Apple security gates

Developer Mode on the phone and code signing on the Mac are separate. Developer Mode permits development apps to run; it does not create a Mac certificate.

If `security find-identity -v -p codesigning` returns zero while Xcode lists an organization certificate, that certificate may be cloud-managed or may lack a private key on this Mac. Use **Your Name (Personal Team)** for the prototype and create an **Apple Development** certificate for that team. An organization Admin is needed only to revoke or manage the organization's certificate.

Apple requires the Apple Account sign-in, certificate creation, iPhone **Trust**, camera permission, and Developer Mode confirmation through protected system UI. VS Code cannot accept those prompts. They happen once; subsequent compile/deploy work uses the tasks above.

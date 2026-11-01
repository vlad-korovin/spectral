import SwiftUI

@MainActor final class StudioState: ObservableObject {
    @Published var resetToken = UUID()
    @Published var captureToken = UUID()
    @Published var status = "Starting camera…"
    @Published var performance = "Measuring renderer…"
    @Published var roomCaustics = true
    @Published var lightLocked = false
    @Published var lightTool = false
    @Published var lightStyle: LightingStyle = .soft
    @Published var idleAnimation = true
    @Published var cinematicIdle = true
    @Published var placementMode: CrystalPlacement = .space
    @Published var restToken = UUID()
    @Published var reduceMotion = false
    @Published var motionPaused = false
    @Published var touchingControls = false
    @Published var automaticHands = true
    @Published var lightPlaced = false
    @Published var lightStops: Float = 0.7
    @Published var lightRadius: Float = 0.25
    @Published var lightAngle: Float = 0
    @Published var lightWarmth: Float = 0
    @Published var rigLocked = false
    @Published var lightHint = "Tap your subject to paint with light"
    @Published var fillEnabled = true
    @Published var saveRigToken = UUID()
    @Published var restoreRigToken = UUID()
    @Published var hasSavedRig = false
    @Published var placementHint: String?
    @Published var placed = false
    @Published var handPoint: CGPoint?
    @Published var handGrabbing = false
    @Published var handStatus = "Pinch over the crystal, then lift your hand"
    @Published var datasetCapture = false
    @Published var showDepth = false
    @Published var compare = false
    @Published var detail = false
    @Published var capturing = false
    @Published var export: CaptureExport?
    @Published var error: String?
}

struct CaptureExport: Identifiable { let id = UUID(); let url: URL }

struct ContentView: View {
    @StateObject private var studio = StudioState()
    @State private var controls = false
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let accent = Color(red: 0.70,green: 0.96,blue: 0.87)

    private func capture(dataset: Bool) {
        studio.datasetCapture = dataset; studio.capturing = true; studio.captureToken = UUID()
    }
    private func selectTool(_ light: Bool) {
        studio.placementHint = nil
        studio.lightTool = light
        UISelectionFeedbackGenerator().selectionChanged()
    }
    private var prompt: String {
        if studio.lightTool { return studio.lightPlaced ? "Drag to aim · Pinch to spread · Twist the source" : "Tap a subject. Make the light your own." }
        if let hint = studio.placementHint { return hint }
        if !studio.placed {
            return studio.placementMode == .space ? "Tap to place the crystal" : "Tap a surface to place the crystal"
        }
        return studio.handPoint != nil ? studio.handStatus : "Tap to place again · Drag, pinch or twist to adjust"
    }

    var body: some View {
        ZStack {
            PrismARView(studio: studio).ignoresSafeArea()
            GeometryReader { geometry in
                if !studio.lightTool, let point = studio.handPoint {
                    ZStack {
                        Circle().stroke(studio.handGrabbing ? accent : .white.opacity(0.85), lineWidth: 1.5)
                            .frame(width: studio.handGrabbing ? 30 : 46,height: studio.handGrabbing ? 30 : 46)
                        Circle().fill(studio.handGrabbing ? accent : .white).frame(width: 5,height: 5)
                    }
                    .shadow(color: .black.opacity(0.4),radius: 2)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15),value: studio.handGrabbing)
                    .position(x: point.x*geometry.size.width,y: point.y*geometry.size.height)
                }
            }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
            VStack(spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading,spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkle").foregroundStyle(accent)
                            Text("SPECTRAL").font(.system(size: 12,weight: .semibold)).tracking(2.5)
                        }
                        Text(studio.status).font(.caption2).foregroundStyle(.white.opacity(0.8)).lineLimit(2)
                    }.shadow(color: .black.opacity(0.8),radius: 3)
                    Spacer(minLength: 16)
                    Button { controls = true } label: {
                        Image(systemName: "ellipsis").font(.title3).frame(width: 44,height: 44)
                    }.background(.ultraThinMaterial,in: Circle()).accessibilityLabel("Open studio menu")
                }.padding(.horizontal,6)
                Spacer(minLength: 12)
                creativeTray
                    .opacity(studio.handGrabbing ? 0.78 : 1)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2),value: studio.handGrabbing)
                HStack {
                    Text(studio.compare ? "Original" : "Compare")
                        .font(.caption.weight(.medium)).frame(width: 80,height: 48)
                        .background(.ultraThinMaterial,in: Capsule())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { _ in studio.compare = true }
                            .onEnded { _ in studio.compare = false })
                        .accessibilityAddTraits(.isButton).accessibilityAction { studio.compare.toggle() }
                    Spacer()
                    Button { capture(dataset: false) } label: {
                        ZStack {
                            Circle().stroke(AngularGradient(colors: [accent,.white,Color(red: 0.77,green: 0.70,blue: 1),accent],center: .center),lineWidth: 3)
                                .frame(width: 72,height: 72)
                            Circle().fill(.white).frame(width: 58,height: 58)
                            if studio.capturing { ProgressView().tint(.black) }
                        }
                    }.disabled(studio.capturing).accessibilityLabel("Capture clean photo")
                    Spacer()
                    Button { studio.rigLocked.toggle() } label: {
                        Label(studio.rigLocked ? "Held" : "Hold",systemImage: studio.rigLocked ? "lock.fill" : "lock.open")
                            .font(.caption).frame(width: 80,height: 48)
                    }.background(.ultraThinMaterial,in: Capsule())
                        .foregroundStyle(studio.rigLocked ? accent : .white)
                        .accessibilityLabel(studio.rigLocked ? "Release composition hold" : "Hold composition")
                }.padding(.horizontal,12)
            }.padding(.horizontal,18).padding(.top,8).padding(.bottom,8)
        }
        .preferredColorScheme(.dark).tint(accent)
        .sheet(isPresented: $controls) { studioMenu }
        .sheet(item: $studio.export) { ShareCapture(url: $0.url) }
        .alert("Capture unavailable",isPresented: Binding(get: { studio.error != nil },set: { if !$0 { studio.error = nil } })) {
            Button("OK") { studio.error = nil }
        } message: { Text(studio.error ?? "") }
        .onAppear { studio.reduceMotion = reduceMotion; studio.motionPaused = phase != .active || controls }
        .onChange(of: reduceMotion) { _, next in studio.reduceMotion = next }
        .onChange(of: controls) { _, next in studio.motionPaused = next || phase != .active; studio.touchingControls = false }
        .onChange(of: phase) { _, next in
            if next != .active { studio.compare = false; studio.touchingControls = false }
            studio.motionPaused = next != .active || controls
        }
    }

    private var creativeTray: some View {
        VStack(spacing: 13) {
            HStack(spacing: 8) {
                toolButton("Crystal",icon: "diamond",light: false)
                toolButton("Light",icon: "sun.max",light: true)
                Spacer(minLength: 0)
                if !studio.lightTool && studio.placed {
                    Button {
                        if studio.idleAnimation { studio.idleAnimation = false; studio.restToken = UUID() }
                        else { studio.idleAnimation = true }
                    } label: {
                        Label(studio.idleAnimation ? "Rest" : "Float",systemImage: studio.idleAnimation ? "pause" : "sparkles")
                            .font(.caption.weight(.medium)).frame(minWidth: 52,minHeight: 44)
                    }.disabled(studio.reduceMotion && !studio.idleAnimation)
                }
            }
            if studio.lightTool {
                ScrollView(.horizontal,showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(LightingStyle.allCases) { style in
                            Button {
                                studio.lightStyle = style; UISelectionFeedbackGenerator().selectionChanged()
                            } label: {
                                VStack(spacing: 5) {
                                    LightGlyph(style: style).frame(width: 38,height: 32)
                                    Text(style.title).font(.system(size: 10,weight: .medium))
                                }.frame(width: 52,height: 57)
                                    .background(studio.lightStyle == style ? .white.opacity(0.12) : .clear,in: RoundedRectangle(cornerRadius: 13))
                                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(studio.lightStyle == style ? accent.opacity(0.7) : .clear,lineWidth: 1))
                            }.buttonStyle(.plain).accessibilityLabel(style.title+" lighting")
                                .accessibilityAddTraits(studio.lightStyle == style ? .isSelected : [])
                        }
                    }.padding(1)
                }
                if studio.lightPlaced {
                    HStack(spacing: 10) {
                        Image(systemName: "sun.min").font(.caption)
                        Slider(value: $studio.lightStops,in: 0...1.5).accessibilityLabel("Light strength")
                        Image(systemName: "sun.max").font(.caption)
                    }
                }
            }
            Text(prompt).font(.system(size: 12,weight: .medium)).foregroundStyle(.white.opacity(0.85))
                .lineLimit(2).multilineTextAlignment(.center).frame(maxWidth: .infinity)
        }
        .padding(14).background(.ultraThinMaterial,in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(LinearGradient(colors: [.white.opacity(0.22),.white.opacity(0.03)],startPoint: .topLeading,endPoint: .bottomTrailing),lineWidth: 0.5))
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in if !studio.touchingControls { studio.touchingControls = true } }
            .onEnded { _ in studio.touchingControls = false })
    }

    private func toolButton(_ title: String, icon: String, light: Bool) -> some View {
        Button { selectTool(light) } label: {
            Label(title,systemImage: icon).font(.system(size: 13,weight: .semibold))
                .padding(.horizontal,13).frame(height: 44)
                .background(studio.lightTool == light ? accent.opacity(0.16) : .clear,in: Capsule())
                .foregroundStyle(studio.lightTool == light ? accent : .white.opacity(0.65))
        }.buttonStyle(.plain).accessibilityAddTraits(studio.lightTool == light ? .isSelected : [])
    }

    private var studioMenu: some View {
        NavigationStack {
            Form {
                Section("Your crystal") {
                    Picker("Place in",selection: $studio.placementMode) {
                        ForEach(CrystalPlacement.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Recognize hand gestures",isOn: $studio.automaticHands)
                    Text("Touch always takes over. Pinch over the crystal to grab, lift or sweep your hand to move, then open to release. Bring your hand nearer or farther when tracking is steady.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Idle flight",isOn: $studio.idleAnimation).disabled(studio.reduceMotion)
                    Toggle("Cinematic reflections",isOn: $studio.cinematicIdle)
                    Text("Untouched for three seconds, the crystal rises into a gentle orbit. Reach in to catch it.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Shape the light") {
                    Toggle("Surface fill",isOn: $studio.fillEnabled)
                    LabeledContent("Width") { Slider(value: $studio.lightRadius,in: 0.06...0.8).accessibilityLabel("Light width") }
                    LabeledContent("Direction") { Slider(value: $studio.lightAngle,in: -Float.pi...Float.pi).accessibilityLabel("Light direction") }
                    LabeledContent("Cool / warm") { Slider(value: $studio.lightWarmth,in: -1...1).accessibilityLabel("Light tint") }
                    Button("Remember this light") { studio.saveRigToken = UUID() }.disabled(!studio.lightPlaced)
                    Button("Recall light") { studio.restoreRigToken = UUID() }.disabled(!studio.hasSavedRig)
                    Toggle("Room-light caustics",isOn: $studio.roomCaustics)
                    Toggle("Lock room lighting",isOn: $studio.lightLocked)
                }
                Section("Quality & capture") {
                    Toggle("Studio quality",isOn: $studio.detail)
                    Text("Photos use full display resolution. Live quality affects preview cost.").font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Capture Lab") {
                        Text(studio.performance).font(.caption.monospacedDigit())
                        Toggle("Inspect scene depth",isOn: $studio.showDepth)
                        Button("Export synchronized dataset") { controls = false; capture(dataset: true) }.disabled(studio.capturing)
                    }
                }
                Section {
                    Button("Start a fresh scene",role: .destructive) { studio.resetToken = UUID(); controls = false }
                }
            }.navigationTitle("Spectral")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { controls = false } } }
        }.presentationDetents([.medium,.large]).presentationDragIndicator(.visible)
    }
}

// Tiny code-drawn aperture previews: no image downloads or per-frame animation.
private struct LightGlyph: View {
    let style: LightingStyle
    private let glow = Color(red: 0.96,green: 0.86,blue: 0.66)
    var body: some View {
        ZStack {
            switch style {
            case .soft:
                Circle().fill(RadialGradient(colors: [glow,.clear],center: .center,startRadius: 1,endRadius: 18))
            case .spot:
                Circle().fill(RadialGradient(colors: [glow,glow.opacity(0.2)],center: .center,startRadius: 6,endRadius: 14)).padding(3)
            case .strip:
                RoundedRectangle(cornerRadius: 4).fill(LinearGradient(colors: [glow.opacity(0.2),glow,glow.opacity(0.2)],startPoint: .top,endPoint: .bottom)).frame(width: 10)
            case .window:
                VStack(spacing: 3) { ForEach(0..<2) { _ in HStack(spacing: 3) {
                    ForEach(0..<2) { _ in RoundedRectangle(cornerRadius: 2).fill(glow.opacity(0.8)) }
                } } }.padding(3)
            case .halo:
                Circle().stroke(LinearGradient(colors: [glow,.white.opacity(0.3)],startPoint: .topLeading,endPoint: .bottomTrailing),lineWidth: 4).padding(4)
            }
        }.accessibilityHidden(true)
    }
}

private struct ShareCapture: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url],applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController,context: Context) {}
}

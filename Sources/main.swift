import Cocoa
import SwiftUI
import ServiceManagement

// MARK: - App Scroll Profile

struct AppScrollProfile: Codable, Equatable {
    var speed: Double
    var damping: Double
    var instantStop: Bool
    var momentumFriction: Double
    var excluded: Bool

    static func fromGlobal() -> AppScrollProfile {
        AppScrollProfile(
            speed: Settings.speed,
            damping: Settings.damping,
            instantStop: Settings.instantStop,
            momentumFriction: Settings.momentumFriction,
            excluded: false
        )
    }
}

// MARK: - Settings (UserDefaults)

struct Settings {
    private static let defaults = UserDefaults.standard

    static var speed: Double {
        get { defaults.object(forKey: "speed") as? Double ?? 0.6 }
        set { defaults.set(newValue, forKey: "speed") }
    }

    static var damping: Double {
        get { defaults.object(forKey: "damping") as? Double ?? 0.02 }
        set { defaults.set(newValue, forKey: "damping") }
    }

    static var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    static var instantStop: Bool {
        get { defaults.object(forKey: "instantStop") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "instantStop") }
    }

    static var momentumFriction: Double {
        get { defaults.object(forKey: "momentumFriction") as? Double ?? 0.15 }
        set { defaults.set(newValue, forKey: "momentumFriction") }
    }

    static var modifierKeysEnabled: Bool {
        get { defaults.object(forKey: "modifierKeysEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "modifierKeysEnabled") }
    }

    static var gesturePhasesEnabled: Bool {
        get { defaults.object(forKey: "gesturePhasesEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "gesturePhasesEnabled") }
    }

    static var appProfiles: [String: AppScrollProfile] {
        get {
            guard let data = defaults.data(forKey: "appProfiles"),
                  let dict = try? JSONDecoder().decode([String: AppScrollProfile].self, from: data)
            else { return [:] }
            return dict
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "appProfiles")
            }
        }
    }

    static var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: "hasCompletedOnboarding") }
        set { defaults.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    static var excludedApps: [String] {
        get { defaults.stringArray(forKey: "excludedApps") ?? [] }
        set { defaults.set(newValue, forKey: "excludedApps") }
    }
}

// MARK: - SmoothScrollManager

class SmoothScrollManager: ObservableObject {
    static let shared = SmoothScrollManager()

    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var timer: DispatchSourceTimer?
    private var displayLink: CADisplayLink?
    private var lastFrameTime: Double = 0

    private enum Gesture { case idle, scrolling, momentumPending, momentum }
    private var gesture: Gesture = .idle

    private var accY: Double = 0
    private var accX: Double = 0
    private var errY: Double = 0
    private var errX: Double = 0
    private var animating = false
    private var lastScrollTime: Double = 0

    private var activeDamping: Double = Settings.damping
    private var activeInstantStop: Bool = Settings.instantStop
    private var activeMomentumFriction: Double = Settings.momentumFriction

    private var zoomAcc: Double = 0
    private var zoomTimer: DispatchSourceTimer?
    private var zoomAnimating = false
    private var lastZoomTime: Double = 0
    private var zoomPhaseActive = false
    private var zoomMouseLocation: CGPoint = .zero

    @Published var enabled: Bool = Settings.enabled { didSet { Settings.enabled = enabled } }
    @Published var speed: Double = Settings.speed { didSet { Settings.speed = speed } }
    @Published var damping: Double = Settings.damping { didSet { Settings.damping = damping } }
    @Published var instantStop: Bool = Settings.instantStop { didSet { Settings.instantStop = instantStop } }
    @Published var momentumFriction: Double = Settings.momentumFriction { didSet { Settings.momentumFriction = momentumFriction } }
    @Published var modifierKeysEnabled: Bool = Settings.modifierKeysEnabled { didSet { Settings.modifierKeysEnabled = modifierKeysEnabled } }
    @Published var gesturePhasesEnabled: Bool = Settings.gesturePhasesEnabled { didSet { Settings.gesturePhasesEnabled = gesturePhasesEnabled } }
    @Published var appProfiles: [String: AppScrollProfile] = Settings.appProfiles {
        didSet { Settings.appProfiles = appProfiles }
    }

    private let fps: Double = 120
    private let scrollMultiplier: Double = 5.0

    init() {
        migrateExcludedAppsIfNeeded()
    }

    private func migrateExcludedAppsIfNeeded() {
        let defaults = UserDefaults.standard
        if let oldExcluded = defaults.stringArray(forKey: "excludedApps"), !oldExcluded.isEmpty {
            var profiles = appProfiles
            for bundleId in oldExcluded {
                if profiles[bundleId] == nil {
                    profiles[bundleId] = AppScrollProfile(
                        speed: speed, damping: damping,
                        instantStop: instantStop, momentumFriction: momentumFriction,
                        excluded: true
                    )
                }
            }
            appProfiles = profiles
            defaults.removeObject(forKey: "excludedApps")
        }
    }

    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        eventTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        runLoopSource = src
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        endAnimation()
        if zoomPhaseActive {
            postMagnifyEvent(magnification: 0, phase: 4)
            zoomPhaseActive = false
        }
        zoomTimer?.cancel()
        zoomTimer = nil
        zoomAnimating = false
        zoomAcc = 0
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
    }

    fileprivate func handleScroll(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard enabled else { return Unmanaged.passUnretained(event) }

        var effectiveSpeed = speed
        var effectiveDamping = damping
        var effectiveInstantStop = instantStop
        var effectiveMomentumFriction = momentumFriction

        if let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           let profile = appProfiles[bundleId] {
            if profile.excluded {
                return Unmanaged.passUnretained(event)
            }
            effectiveSpeed = profile.speed
            effectiveDamping = profile.damping
            effectiveInstantStop = profile.instantStop
            effectiveMomentumFriction = profile.momentumFriction
        }

        let dy = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let dx = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)

        if phase != 0 || momentum != 0 {
            return Unmanaged.passUnretained(event)
        }

        var finalDy = dy
        var finalDx = dx

        if modifierKeysEnabled {
            let flags = event.flags
            // Ctrl+scroll = smooth pinch-to-zoom (magnification gesture)
            if flags.contains(.maskControl) {
                endAnimation()
                if dy != 0 {
                    zoomAcc += Double(dy) * 0.06
                    zoomMouseLocation = event.location
                    lastZoomTime = CACurrentMediaTime()
                    startZoomAnimation()
                }
                return nil
            }
            if flags.contains(.maskShift) {
                // Force horizontal: take whichever axis has value
                if dy != 0 {
                    finalDy = 0
                    finalDx = dy
                }
            }
            if flags.contains(.maskCommand) {
                effectiveSpeed *= 2.0
            }
            if flags.contains(.maskAlternate) {
                effectiveSpeed *= 0.3
            }
        }

        if (Double(finalDy) > 0 && accY < 0) || (Double(finalDy) < 0 && accY > 0) {
            accY = 0; errY = 0
        }
        if (Double(finalDx) > 0 && accX < 0) || (Double(finalDx) < 0 && accX > 0) {
            accX = 0; errX = 0
        }

        // New wheel input while coasting = fingers back on the trackpad
        if gesture == .momentum || gesture == .momentumPending {
            finishGesture()
        }

        accY += Double(finalDy) * effectiveSpeed * scrollMultiplier
        accX += Double(finalDx) * effectiveSpeed * scrollMultiplier
        lastScrollTime = CACurrentMediaTime()

        activeDamping = effectiveDamping
        activeInstantStop = effectiveInstantStop
        activeMomentumFriction = effectiveMomentumFriction

        startAnimation()
        return nil
    }

    private func startAnimation() {
        guard !animating else { return }
        animating = true
        lastFrameTime = 0

        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            // Tick in sync with the refresh of the display under the cursor
            let link = screen.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
            let maxFps = Float(screen.maximumFramesPerSecond)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maxFps), maximum: maxFps, preferred: maxFps)
            link.add(to: .main, forMode: .common)
            displayLink = link
            return
        }

        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1.0 / fps)
        t.setEventHandler { [weak self] in self?.tick(frames: 1) }
        t.resume()
        timer = t
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        let dt = link.targetTimestamp - (lastFrameTime > 0 ? lastFrameTime : link.timestamp)
        lastFrameTime = link.targetTimestamp
        tick(frames: min(dt, 0.05) * fps)
    }

    private func endAnimation() {
        displayLink?.invalidate()
        displayLink = nil
        timer?.cancel()
        timer = nil
        animating = false
        accY = 0; accX = 0
        errY = 0; errX = 0
        finishGesture()
    }

    // `frames` = elapsed time in units of one frame at `fps`, which damping values are tuned for
    private func tick(frames: Double) {
        let idle = CACurrentMediaTime() - lastScrollTime > 0.15

        if idle && activeInstantStop {
            endAnimation()
            return
        }

        if idle && gesture == .scrolling {
            // Wheel stopped: lift the "fingers", the rest coasts as momentum
            post(pxY: 0, pxX: 0, scrollPhase: .ended)
            gesture = .momentumPending
        }

        let d = idle ? activeMomentumFriction : max(activeDamping, 0.03)
        let k = 1 - pow(1 - d, frames)

        let stepY = accY * k
        let stepX = accX * k

        accY -= stepY
        accX -= stepX

        postEvent(dy: stepY, dx: stepX)

        // An open gesture stays alive between wheel notches until the wheel goes idle
        if abs(accY) < 0.5 && abs(accX) < 0.5 && (idle || gesture != .scrolling) {
            endAnimation()
        }
    }

    private func postEvent(dy: Double, dx: Double) {
        let adjY = dy + errY
        let adjX = dx + errX
        let pxY = Int32(round(adjY))
        let pxX = Int32(round(adjX))
        errY = adjY - Double(pxY)
        errX = adjX - Double(pxX)

        guard pxY != 0 || pxX != 0 else { return }

        switch gesture {
        case .idle:
            if gesturePhasesEnabled {
                gesture = .scrolling
                post(pxY: pxY, pxX: pxX, scrollPhase: .began)
            } else {
                post(pxY: pxY, pxX: pxX)
            }
        case .scrolling:
            post(pxY: pxY, pxX: pxX, scrollPhase: .changed)
        case .momentumPending:
            gesture = .momentum
            post(pxY: pxY, pxX: pxX, momentumPhase: .begin)
        case .momentum:
            post(pxY: pxY, pxX: pxX, momentumPhase: .continuous)
        }
    }

    // Trackpad-style sequence: began → changed… → ended, then momentum begin → continuous… → end
    private func finishGesture() {
        switch gesture {
        case .scrolling: post(pxY: 0, pxX: 0, scrollPhase: .ended)
        case .momentum: post(pxY: 0, pxX: 0, momentumPhase: .end)
        case .idle, .momentumPending: break
        }
        gesture = .idle
    }

    private func post(pxY: Int32, pxX: Int32,
                      scrollPhase: CGScrollPhase? = nil,
                      momentumPhase: CGMomentumScrollPhase = .none) {
        guard let ev = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: pxY,
            wheel2: pxX,
            wheel3: 0
        ) else { return }

        ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        ev.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(scrollPhase?.rawValue ?? 0))
        ev.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentumPhase.rawValue))
        ev.post(tap: .cgSessionEventTap)
    }

    // MARK: - Smooth Zoom (Magnification Gesture)

    private func startZoomAnimation() {
        if !zoomPhaseActive {
            postMagnifyEvent(magnification: 0, phase: 1) // kIOHIDEventPhaseBegan
            zoomPhaseActive = true
        }
        guard !zoomAnimating else { return }
        zoomAnimating = true
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1.0 / fps)
        t.setEventHandler { [weak self] in self?.zoomTick() }
        t.resume()
        zoomTimer = t
    }

    private func zoomTick() {
        let step = zoomAcc * 0.15
        zoomAcc -= step

        if abs(step) > 0.000005 {
            postMagnifyEvent(magnification: step, phase: 2) // kIOHIDEventPhaseChanged
        }

        if abs(zoomAcc) < 0.0002 {
            if zoomPhaseActive {
                postMagnifyEvent(magnification: 0, phase: 4) // kIOHIDEventPhaseEnded
                zoomPhaseActive = false
            }
            zoomAcc = 0
            zoomTimer?.cancel()
            zoomTimer = nil
            zoomAnimating = false
        }
    }

    private func postMagnifyEvent(magnification: Double, phase: Int64) {
        guard let event = CGEvent(source: nil) else { return }
        event.type = CGEventType(rawValue: 29)! // NSEventTypeGesture / magnify
        event.location = zoomMouseLocation
        event.setIntegerValueField(CGEventField(rawValue: 110)!, value: 8) // kIOHIDEventTypeZoom
        event.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
        event.setDoubleValueField(CGEventField(rawValue: 113)!, value: magnification)
        event.post(tap: .cghidEventTap)
    }
}

// MARK: - Event Tap Callback

private let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
    let mgr = Unmanaged<SmoothScrollManager>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = mgr.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }

    return mgr.handleScroll(event)
}

// MARK: - Presets

struct ScrollPreset: Identifiable {
    let id: String
    let name: String
    let icon: String
    let speed: Double
    let damping: Double
    let desc: String
    let color: Color
    let gradientColors: [Color]
}

let presets = [
    ScrollPreset(id: "silky", name: "Silky", icon: "wind",
                 speed: 0.3, damping: 0.008, desc: "Ultra-smooth, gentle",
                 color: .purple, gradientColors: [.purple, .pink]),
    ScrollPreset(id: "balanced", name: "Balanced", icon: "circle.grid.2x2",
                 speed: 0.6, damping: 0.02, desc: "Best for most users",
                 color: .blue, gradientColors: [.blue, .cyan]),
    ScrollPreset(id: "fast", name: "Fast", icon: "hare",
                 speed: 1.2, damping: 0.06, desc: "Quick & responsive",
                 color: .orange, gradientColors: [.orange, .yellow]),
    ScrollPreset(id: "precise", name: "Precise", icon: "scope",
                 speed: 0.2, damping: 0.012, desc: "Pixel-perfect control",
                 color: .green, gradientColors: [.green, .mint]),
]

// MARK: - Damping mapping (log scale)

func dampingToSlider(_ d: Double) -> Double {
    let lo = log(0.005), hi = log(0.20)
    return (log(max(d, 0.005)) - lo) / (hi - lo)
}

func sliderToDamping(_ s: Double) -> Double {
    let lo = log(0.005), hi = log(0.20)
    return exp(lo + s * (hi - lo))
}

func dampingLabel(_ d: Double) -> String {
    if d < 0.012 { return "Very Smooth" }
    if d < 0.035 { return "Smooth" }
    if d < 0.07 { return "Normal" }
    return "Responsive"
}

// MARK: - SwiftUI Settings View

struct SettingsView: View {
    @ObservedObject var manager = SmoothScrollManager.shared
    @State private var dampingSlider: Double
    @State private var selectedPreset: String?
    @State private var profileList: [String]
    @State private var editingProfile: String? = nil

    init() {
        let mgr = SmoothScrollManager.shared
        _dampingSlider = State(initialValue: dampingToSlider(mgr.damping))
        _profileList = State(initialValue: Array(mgr.appProfiles.keys).sorted())

        var matched: String? = nil
        for p in presets {
            if abs(mgr.speed - p.speed) < 0.01 && abs(mgr.damping - p.damping) < 0.001 {
                matched = p.id
            }
        }
        _selectedPreset = State(initialValue: matched)
    }

    private var accentColor: Color {
        if let id = selectedPreset, let preset = presets.first(where: { $0.id == id }) {
            return preset.color
        }
        return .gray
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("SmoothScroll")
                        .font(.title2.bold())
                    Text("Smooth mouse scrolling for macOS")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 16)

            ScrollView {
                VStack(spacing: 18) {
                    presetsCard
                    slidersCard
                    appProfilesCard
                    modifierKeysCard
                    generalCard
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .frame(minWidth: 420, idealWidth: 720, minHeight: 520, idealHeight: 780)
        .background(.ultraThinMaterial)
    }

    // MARK: Presets Card

    private var presetsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Presets", systemImage: "slider.horizontal.3")
                .font(.headline)

            HStack(spacing: 10) {
                ForEach(presets) { preset in
                    presetTile(
                        title: preset.name, icon: preset.icon,
                        desc: preset.desc, selected: selectedPreset == preset.id,
                        tileColor: preset.color
                    ) {
                        applyPreset(preset)
                    }
                }

                presetTile(
                    title: "Custom", icon: "slider.horizontal.2.square",
                    desc: "Your own settings",
                    selected: selectedPreset == nil,
                    tileColor: .gray
                ) { }
                .opacity(selectedPreset == nil ? 1.0 : 0.5)
                .allowsHitTesting(false)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Sliders Card

    private var slidersCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Fine Tuning", systemImage: "tuningfork")
                .font(.headline)

            HStack(spacing: 10) {
                behaviorTile(
                    title: "Instant Stop",
                    icon: "stop.circle.fill",
                    desc: "Stops where you left off",
                    selected: manager.instantStop
                ) {
                    manager.instantStop = true
                }

                behaviorTile(
                    title: "Momentum",
                    icon: "arrow.up.arrow.down.circle.fill",
                    desc: "Coasts like a trackpad",
                    selected: !manager.instantStop
                ) {
                    manager.instantStop = false
                }
            }

            if !manager.instantStop {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Coast Duration")
                        Spacer()
                        Text(coastLabel(manager.momentumFriction))
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)

                    Slider(value: Binding(
                        get: { 1.0 - momentumToSlider(manager.momentumFriction) },
                        set: { manager.momentumFriction = sliderToMomentum(1.0 - $0) }
                    ), in: 0...1)

                    HStack {
                        Text("Short").font(.caption2).foregroundStyle(.tertiary)
                        Spacer()
                        Text("Long").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .padding(.top, 4)
            }

            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Scroll Distance")
                    Spacer()
                    Text(String(format: "%.2fx", manager.speed))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.subheadline)

                Slider(value: $manager.speed, in: 0.05...3.0) { _ in
                    selectedPreset = nil
                }

                HStack {
                    Text("Less").font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Text("More").font(.caption2).foregroundStyle(.tertiary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Smoothness")
                    Spacer()
                    Text(dampingLabel(manager.damping))
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)

                Slider(value: $dampingSlider, in: 0...1) { _ in
                    manager.damping = sliderToDamping(dampingSlider)
                    selectedPreset = nil
                }

                HStack {
                    Text("Very Smooth").font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Text("Responsive").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .tint(accentColor)
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .animation(.easeInOut(duration: 0.3), value: selectedPreset)
    }

    // MARK: App Profiles Card

    private var appProfilesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Per-App Profiles", systemImage: "app.badge.checkmark")
                .font(.headline)

            Text("Customize scroll behavior for individual apps, or disable smooth scrolling entirely.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if profileList.isEmpty {
                Text("No per-app profiles \u{2014} global settings apply everywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 14)
            } else {
                VStack(spacing: 0) {
                    ForEach(profileList, id: \.self) { bundleId in
                        appProfileRow(bundleId: bundleId)
                        if bundleId != profileList.last {
                            Divider().padding(.leading, 32).opacity(0.4)
                        }
                    }
                }
                .padding(6)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }

            Menu {
                let apps = NSWorkspace.shared.runningApplications
                    .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
                    .filter { !profileList.contains($0.bundleIdentifier!) }
                    .filter { $0.bundleIdentifier != "com.local.smoothscroll" }
                    .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }

                if apps.isEmpty {
                    Text("No apps to add")
                } else {
                    ForEach(apps, id: \.processIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "?") {
                            if let bid = app.bundleIdentifier {
                                addProfile(bid)
                            }
                        }
                    }
                }
            } label: {
                Label("Add App...", systemImage: "plus")
                    .font(.subheadline)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func appProfileRow(bundleId: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                appIcon(for: bundleId)
                    .frame(width: 22, height: 22)
                Text(appName(for: bundleId))
                    .font(.subheadline)
                Spacer()

                if let profile = manager.appProfiles[bundleId] {
                    Text(profile.excluded ? "Disabled" : String(format: "%.1fx", profile.speed))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        editingProfile = (editingProfile == bundleId) ? nil : bundleId
                    }
                } label: {
                    Image(systemName: editingProfile == bundleId ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Button {
                    removeProfile(bundleId)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.red.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)

            if editingProfile == bundleId {
                appProfileEditor(bundleId: bundleId)
            }
        }
    }

    private func appProfileEditor(bundleId: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Disable smooth scrolling for this app", isOn: Binding(
                get: { manager.appProfiles[bundleId]?.excluded ?? false },
                set: { newVal in
                    manager.appProfiles[bundleId]?.excluded = newVal
                }
            ))
            .font(.subheadline)

            if !(manager.appProfiles[bundleId]?.excluded ?? true) {
                HStack(spacing: 6) {
                    Text("Preset:").font(.caption).foregroundStyle(.secondary)
                    ForEach(presets) { preset in
                        Button(preset.name) {
                            manager.appProfiles[bundleId]?.speed = preset.speed
                            manager.appProfiles[bundleId]?.damping = preset.damping
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Button("Global") {
                        manager.appProfiles[bundleId]?.speed = manager.speed
                        manager.appProfiles[bundleId]?.damping = manager.damping
                        manager.appProfiles[bundleId]?.instantStop = manager.instantStop
                        manager.appProfiles[bundleId]?.momentumFriction = manager.momentumFriction
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Speed")
                        Spacer()
                        Text(String(format: "%.2fx", manager.appProfiles[bundleId]?.speed ?? 0.6))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.caption)
                    Slider(value: Binding(
                        get: { manager.appProfiles[bundleId]?.speed ?? 0.6 },
                        set: { manager.appProfiles[bundleId]?.speed = $0 }
                    ), in: 0.05...3.0)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Smoothness")
                        Spacer()
                        Text(dampingLabel(manager.appProfiles[bundleId]?.damping ?? 0.02))
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    Slider(value: Binding(
                        get: { dampingToSlider(manager.appProfiles[bundleId]?.damping ?? 0.02) },
                        set: { manager.appProfiles[bundleId]?.damping = sliderToDamping($0) }
                    ), in: 0...1)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    // MARK: Modifier Keys Card

    private var modifierKeysCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Modifier Keys", systemImage: "command.square")
                    .font(.headline)
                Spacer()
                Toggle("", isOn: $manager.modifierKeysEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            if manager.modifierKeysEnabled {
                VStack(spacing: 8) {
                    modifierRow(icon: "shift", title: "Shift + Scroll", desc: "Scroll horizontally")
                    Divider().padding(.leading, 36).opacity(0.4)
                    modifierRow(icon: "command", title: "Cmd + Scroll", desc: "2x faster scrolling")
                    Divider().padding(.leading, 36).opacity(0.4)
                    modifierRow(icon: "option", title: "Option + Scroll", desc: "Precise / slow scrolling (0.3x)")
                    Divider().padding(.leading, 36).opacity(0.4)
                    modifierRow(icon: "control", title: "Ctrl + Scroll", desc: "Smooth pinch zoom")
                }
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func modifierRow(icon: String, title: String, desc: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }

    // MARK: General Card

    private var generalCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("General", systemImage: "gearshape")
                .font(.headline)

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Launch at Login")
                        .font(.subheadline)
                    Text("Start SmoothScroll automatically when you log in")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {}
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            .padding(.horizontal, 4)

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Trackpad Gestures")
                        .font(.subheadline)
                    Text("Send scroll phases so apps bounce at edges like with a trackpad")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $manager.gesturePhasesEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(.horizontal, 4)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Tile Helpers

    private func presetTile(title: String, icon: String, desc: String,
                            selected: Bool, tileColor: Color = .blue,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(selected ? tileColor : .secondary)
                    .frame(height: 28)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(desc)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .background(selected ? AnyShapeStyle(tileColor.opacity(0.12)) : AnyShapeStyle(.clear))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selected ? tileColor.opacity(0.5) : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func behaviorTile(title: String, icon: String, desc: String,
                              selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(selected ? accentColor : .secondary)
                    .frame(height: 28)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(desc)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .background(selected ? AnyShapeStyle(accentColor.opacity(0.12)) : AnyShapeStyle(.clear))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selected ? accentColor.opacity(0.5) : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func momentumToSlider(_ f: Double) -> Double {
        let lo = log(0.03), hi = log(0.40)
        return (log(max(f, 0.03)) - lo) / (hi - lo)
    }

    private func sliderToMomentum(_ s: Double) -> Double {
        let lo = log(0.03), hi = log(0.40)
        return exp(lo + s * (hi - lo))
    }

    private func coastLabel(_ f: Double) -> String {
        if f < 0.06 { return "Very Long" }
        if f < 0.12 { return "Long" }
        if f < 0.22 { return "Medium" }
        return "Short"
    }

    private func applyPreset(_ preset: ScrollPreset) {
        withAnimation(.spring(duration: 0.4)) {
            selectedPreset = preset.id
        }
        manager.speed = preset.speed
        manager.damping = preset.damping
        dampingSlider = dampingToSlider(preset.damping)
    }

    private func addProfile(_ bundleId: String) {
        let profile = AppScrollProfile.fromGlobal()
        manager.appProfiles[bundleId] = profile
        profileList = Array(manager.appProfiles.keys).sorted()
        withAnimation(.easeInOut(duration: 0.2)) {
            editingProfile = bundleId
        }
    }

    private func removeProfile(_ bundleId: String) {
        manager.appProfiles.removeValue(forKey: bundleId)
        profileList = Array(manager.appProfiles.keys).sorted()
        if editingProfile == bundleId { editingProfile = nil }
    }

    private func appName(for bundleId: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleId
    }

    private func appIcon(for bundleId: String) -> Image {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            let nsImage = NSWorkspace.shared.icon(forFile: url.path)
            return Image(nsImage: nsImage)
        }
        return Image(systemName: "app")
    }
}

// MARK: - Onboarding View

struct OnboardingView: View {
    @State private var step = 0
    @State private var selectedPreset: String? = "balanced"
    @State private var accessibilityGranted = AXIsProcessTrusted()
    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Step indicator
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule()
                        .fill(i == step ? Color.blue : Color.secondary.opacity(0.25))
                        .frame(width: i == step ? 24 : 8, height: 8)
                        .animation(.spring(duration: 0.3), value: step)
                }
            }
            .padding(.top, 24)

            Spacer()

            Group {
                switch step {
                case 0: welcomeStep
                case 1: presetStep
                default: permissionStep
                }
            }

            Spacer()

            // Navigation
            HStack {
                if step > 0 {
                    Button("Back") {
                        withAnimation(.spring(duration: 0.4)) { step -= 1 }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if step == 2 {
                    Button("Get Started") {
                        finishOnboarding()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!accessibilityGranted)
                } else {
                    Button("Continue") {
                        withAnimation(.spring(duration: 0.4)) { step += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 28)
        }
        .frame(width: 620, height: 500)
        .background(.ultraThinMaterial)
    }

    // MARK: Step 1 - Welcome

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "computermouse")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(.blue)

            Text("Welcome to SmoothScroll")
                .font(.title.bold())

            Text("Transform your mouse wheel into a\nsmooth, fluid scrolling experience.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 32) {
                VStack(spacing: 6) {
                    Image(systemName: "wind")
                        .font(.system(size: 24))
                        .foregroundStyle(.blue)
                    Text("Smooth")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 24))
                        .foregroundStyle(.blue)
                    Text("Tunable")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 6) {
                    Image(systemName: "app.badge.checkmark")
                        .font(.system(size: 24))
                        .foregroundStyle(.blue)
                    Text("Per-App")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 36)
    }

    // MARK: Step 2 - Choose Preset

    private var presetStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(.blue)

            Text("Choose Your Style")
                .font(.title2.bold())

            Text("Pick a scrolling preset. You can fine-tune it later.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                ForEach(presets) { preset in
                    Button {
                        withAnimation(.spring(duration: 0.25)) {
                            selectedPreset = preset.id
                        }
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: preset.icon)
                                .font(.system(size: 24))
                                .foregroundStyle(selectedPreset == preset.id ? preset.color : .secondary)
                                .frame(height: 28)
                            Text(preset.name)
                                .font(.system(size: 12, weight: .semibold))
                            Text(preset.desc)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                        .background(
                            selectedPreset == preset.id
                                ? AnyShapeStyle(preset.color.opacity(0.12))
                                : AnyShapeStyle(.clear)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(selectedPreset == preset.id ? preset.color.opacity(0.5) : Color.secondary.opacity(0.15), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
        }
        .padding(.horizontal, 36)
    }

    // MARK: Step 3 - Accessibility Permission

    private var permissionStep: some View {
        VStack(spacing: 20) {
            Image(systemName: accessibilityGranted
                ? "checkmark.seal.fill" : "lock.shield")
                .font(.system(size: 52, weight: .thin))
                .foregroundStyle(accessibilityGranted ? .green : .orange)

            Text(accessibilityGranted ? "You're All Set!" : "One More Step")
                .font(.title.bold())

            if accessibilityGranted {
                Text("SmoothScroll is ready. Find it in your menu bar.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("SmoothScroll needs Accessibility access\nto intercept and smooth scroll events.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                } label: {
                    Label("Open Accessibility Settings", systemImage: "lock.open")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            HStack(spacing: 10) {
                Image(systemName: accessibilityGranted
                    ? "checkmark.circle.fill" : "circle.dotted")
                    .font(.system(size: 20))
                    .foregroundStyle(accessibilityGranted ? .green : .secondary)
                Text(accessibilityGranted
                    ? "Accessibility permission granted"
                    : "Waiting for permission...")
                    .font(.subheadline)
                    .foregroundStyle(accessibilityGranted ? .primary : .secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal, 36)
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
                accessibilityGranted = AXIsProcessTrusted()
                if accessibilityGranted { timer.invalidate() }
            }
        }
    }

    private func finishOnboarding() {
        if let presetId = selectedPreset,
           let preset = presets.first(where: { $0.id == presetId }) {
            let mgr = SmoothScrollManager.shared
            mgr.speed = preset.speed
            mgr.damping = preset.damping
        }
        Settings.hasCompletedOnboarding = true
        onComplete()
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let manager = SmoothScrollManager.shared
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()

        if Settings.hasCompletedOnboarding {
            requestAccessibilityAndStart()
        } else {
            // Don't prompt yet — onboarding step 3 will handle it
            if AXIsProcessTrusted() {
                _ = manager.start()
            }
            showOnboarding()
        }
    }

    func requestAccessibilityAndStart() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)

        if trusted {
            _ = manager.start()
        } else {
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
                if AXIsProcessTrusted() {
                    timer.invalidate()
                    _ = self.manager.start()
                }
            }
        }
    }

    private func showOnboarding() {
        let onboardingView = OnboardingView {
            self.onboardingWindow?.close()
            self.onboardingWindow = nil
            // Start the event tap after onboarding completes
            if AXIsProcessTrusted() {
                _ = self.manager.start()
            } else {
                self.requestAccessibilityAndStart()
            }
        }

        let hostingController = NSHostingController(rootView: onboardingView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Welcome to SmoothScroll"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 620, height: 500))
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "computermouse", accessibilityDescription: "SmoothScroll") {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "SS"
            }
        }

        let menu = NSMenu()

        let toggleItem = NSMenuItem(title: "Smooth Scrolling", action: #selector(toggle(_:)), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.state = manager.enabled ? .on : .off
        toggleItem.image = NSImage(systemSymbolName: "computermouse", accessibilityDescription: nil)
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func toggle(_ sender: NSMenuItem) {
        manager.enabled.toggle()
        sender.state = manager.enabled ? .on : .off
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let hostingController = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hostingController)
            window.title = "SmoothScroll"
            window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 720, height: 780))
            window.minSize = NSSize(width: 420, height: 520)
            window.maxSize = NSSize(width: 720, height: 920)
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        manager.stop()
        NSApp.terminate(nil)
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

import Cocoa
import SwiftUI
import ServiceManagement

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

    private var accY: Double = 0
    private var accX: Double = 0
    private var errY: Double = 0
    private var errX: Double = 0
    private var animating = false
    private var lastScrollTime: Double = 0

    @Published var enabled: Bool = Settings.enabled { didSet { Settings.enabled = enabled } }
    @Published var speed: Double = Settings.speed { didSet { Settings.speed = speed } }
    @Published var damping: Double = Settings.damping { didSet { Settings.damping = damping } }
    @Published var excludedApps: Set<String> = Set(Settings.excludedApps) {
        didSet { Settings.excludedApps = Array(excludedApps) }
    }

    private let fps: Double = 120

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
        timer?.cancel()
        timer = nil
        animating = false
        accY = 0; accX = 0
        errY = 0; errX = 0
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
    }

    fileprivate func handleScroll(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard enabled else { return Unmanaged.passUnretained(event) }

        if let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           excludedApps.contains(bundleId) {
            return Unmanaged.passUnretained(event)
        }

        let dy = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let dx = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)

        if phase != 0 || momentum != 0 {
            return Unmanaged.passUnretained(event)
        }

        if (Double(dy) > 0 && accY < 0) || (Double(dy) < 0 && accY > 0) {
            accY = 0; errY = 0
        }
        if (Double(dx) > 0 && accX < 0) || (Double(dx) < 0 && accX > 0) {
            accX = 0; errX = 0
        }

        accY += Double(dy) * speed
        accX += Double(dx) * speed
        lastScrollTime = CACurrentMediaTime()

        startAnimation()
        return nil
    }

    private func startAnimation() {
        guard !animating else { return }
        animating = true

        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1.0 / fps)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        // Stop immediately when user stopped scrolling (no new events for 100ms)
        if CACurrentMediaTime() - lastScrollTime > 0.1 {
            accY = 0; accX = 0
            errY = 0; errX = 0
            timer?.cancel()
            timer = nil
            animating = false
            return
        }

        var stepY = accY * damping
        var stepX = accX * damping

        if abs(stepY) < 1.0 && abs(accY) >= 1.0 {
            stepY = copysign(1.0, accY)
        }
        if abs(stepX) < 1.0 && abs(accX) >= 1.0 {
            stepX = copysign(1.0, accX)
        }

        accY -= stepY
        accX -= stepX

        postEvent(dy: stepY, dx: stepX)

        if abs(accY) < 0.5 && abs(accX) < 0.5 {
            accY = 0; accX = 0
            errY = 0; errX = 0
            timer?.cancel()
            timer = nil
            animating = false
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

        guard let ev = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: pxY,
            wheel2: pxX,
            wheel3: 0
        ) else { return }

        ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        ev.post(tap: .cgSessionEventTap)
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
}

let presets = [
    ScrollPreset(id: "silky", name: "Silky", icon: "wind",
                 speed: 0.3, damping: 0.008, desc: "Ultra-smooth, gentle"),
    ScrollPreset(id: "balanced", name: "Balanced", icon: "circle.grid.2x2",
                 speed: 0.6, damping: 0.02, desc: "Best for most users"),
    ScrollPreset(id: "fast", name: "Fast", icon: "hare",
                 speed: 1.2, damping: 0.06, desc: "Quick & responsive"),
    ScrollPreset(id: "precise", name: "Precise", icon: "scope",
                 speed: 0.2, damping: 0.012, desc: "Pixel-perfect control"),
]

// MARK: - Damping ↔ Slider mapping (log scale)

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
    @State private var excludedList: [String]

    init() {
        let mgr = SmoothScrollManager.shared
        _dampingSlider = State(initialValue: dampingToSlider(mgr.damping))
        _excludedList = State(initialValue: Settings.excludedApps)

        // Detect current preset
        var matched: String? = nil
        for p in presets {
            if abs(mgr.speed - p.speed) < 0.01 && abs(mgr.damping - p.damping) < 0.001 {
                matched = p.id
            }
        }
        _selectedPreset = State(initialValue: matched)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "computermouse.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.blue)
                Text("SmoothScroll")
                    .font(.title2.bold())
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 16) {
                    presetsCard
                    slidersCard
                    excludedCard
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .frame(width: 460, height: 560)
        .background(.ultraThinMaterial)
    }

    // MARK: Presets Card

    private var presetsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Presets", systemImage: "slider.horizontal.3")
                .font(.headline)

            HStack(spacing: 10) {
                ForEach(presets) { preset in
                    Button {
                        applyPreset(preset)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: preset.icon)
                                .font(.system(size: 22))
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
                        .padding(.vertical, 12)
                        .padding(.horizontal, 4)
                        .background(
                            selectedPreset == preset.id
                            ? AnyShapeStyle(.blue.opacity(0.15))
                            : AnyShapeStyle(.clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(selectedPreset == preset.id ? .blue : .clear, lineWidth: 1.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Sliders Card

    private var slidersCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Fine Tuning", systemImage: "tuningfork")
                .font(.headline)

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
        .padding(16)
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Excluded Apps Card

    private var excludedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Disabled for Apps", systemImage: "xmark.app")
                .font(.headline)

            if excludedList.isEmpty {
                Text("No excluded apps — smooth scrolling is active everywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(excludedList, id: \.self) { bundleId in
                        HStack {
                            appIcon(for: bundleId)
                                .frame(width: 20, height: 20)
                            Text(appName(for: bundleId))
                                .font(.subheadline)
                            Spacer()
                            Button {
                                removeApp(bundleId)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)

                        if bundleId != excludedList.last {
                            Divider().padding(.leading, 32)
                        }
                    }
                }
                .padding(4)
                .background(.background.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }

            Menu {
                let apps = NSWorkspace.shared.runningApplications
                    .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
                    .filter { !excludedList.contains($0.bundleIdentifier!) }
                    .filter { $0.bundleIdentifier != "com.local.smoothscroll" }
                    .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }

                if apps.isEmpty {
                    Text("No apps to add")
                } else {
                    ForEach(apps, id: \.processIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "?") {
                            if let bid = app.bundleIdentifier {
                                addApp(bid)
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
        .padding(16)
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Actions

    private func applyPreset(_ preset: ScrollPreset) {
        withAnimation(.easeInOut(duration: 0.2)) {
            selectedPreset = preset.id
        }
        manager.speed = preset.speed
        manager.damping = preset.damping
        dampingSlider = dampingToSlider(preset.damping)
    }

    private func addApp(_ bundleId: String) {
        excludedList.append(bundleId)
        manager.excludedApps = Set(excludedList)
        Settings.excludedApps = excludedList
    }

    private func removeApp(_ bundleId: String) {
        excludedList.removeAll { $0 == bundleId }
        manager.excludedApps = Set(excludedList)
        Settings.excludedApps = excludedList
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

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let manager = SmoothScrollManager.shared
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()

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

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            if #available(macOS 11.0, *),
               let img = NSImage(systemSymbolName: "computermouse", accessibilityDescription: "SmoothScroll") {
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
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        if #available(macOS 13.0, *) {
            loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
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
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                    sender.state = .off
                } else {
                    try SMAppService.mainApp.register()
                    sender.state = .on
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Could not change login item"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
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

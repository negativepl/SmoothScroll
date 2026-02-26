import Cocoa
import ServiceManagement

// MARK: - SmoothScrollManager

class SmoothScrollManager {
    static let shared = SmoothScrollManager()

    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var timer: DispatchSourceTimer?

    private var accY: Double = 0
    private var accX: Double = 0
    private var errY: Double = 0
    private var errX: Double = 0
    private var animating = false

    var enabled = true
    var speed: Double = 1.0
    var damping: Double = 0.05 // fraction of remaining scroll consumed per tick

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

        let dy = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let dx = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)


        // Trackpad has scroll phases (began=1, changed=2, ended=4) or momentum phases.
        // Mouse wheel (even Logitech "smooth scroll") has phase=0 and momentum=0.
        let isTrackpad = phase != 0 || momentum != 0
        if isTrackpad {
            return Unmanaged.passUnretained(event)
        }

        // Mouse wheel — accumulate pixel delta and smooth it out
        accY += Double(dy) * speed
        accX += Double(dx) * speed

        startAnimation()
        return nil // suppress original discrete event
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
        var stepY = accY * damping
        var stepX = accX * damping

        // When the exponential step drops below 1px, switch to constant 1px/frame.
        // This prevents visible discrete jumps at the tail — at 120Hz,
        // 1px per frame is imperceptibly smooth.
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
        // Track sub-pixel error to avoid rounding drift
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

        // Mark as continuous so macOS treats it like trackpad scrolling
        ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        // Post downstream of our tap to avoid recursion
        ev.post(tap: .cgSessionEventTap)
    }
}

// MARK: - Event Tap Callback (C function pointer — must not capture context)

private let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
    let mgr = Unmanaged<SmoothScrollManager>.fromOpaque(userInfo).takeUnretainedValue()

    // Re-enable tap if the system disabled it
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = mgr.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }

    return mgr.handleScroll(event)
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let manager = SmoothScrollManager.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()

        // Check accessibility and prompt if needed
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
        toggleItem.state = .on
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        // Speed submenu
        let speedSub = NSMenu()
        for (label, val) in [("Slow", 0.5), ("Normal", 1.0), ("Fast", 2.0), ("Very Fast", 4.0)] {
            let item = NSMenuItem(title: label, action: #selector(setSpeed(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(val * 10)
            item.state = abs(val - manager.speed) < 0.05 ? .on : .off
            speedSub.addItem(item)
        }
        let speedItem = NSMenuItem(title: "Speed", action: nil, keyEquivalent: "")
        speedItem.submenu = speedSub
        menu.addItem(speedItem)

        // Smoothness submenu
        let smoothSub = NSMenu()
        for (label, val) in [("Very Smooth", 0.03), ("Smooth", 0.05), ("Normal", 0.10), ("Responsive", 0.25)] {
            let item = NSMenuItem(title: label, action: #selector(setSmoothness(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(val * 1000)
            item.state = abs(val - manager.damping) < 0.005 ? .on : .off
            smoothSub.addItem(item)
        }
        let smoothItem = NSMenuItem(title: "Smoothness", action: nil, keyEquivalent: "")
        smoothItem.submenu = smoothSub
        menu.addItem(smoothItem)

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

    @objc private func setSpeed(_ sender: NSMenuItem) {
        manager.speed = Double(sender.tag) / 10.0
        sender.menu?.items.forEach { $0.state = .off }
        sender.state = .on
    }

    @objc private func setSmoothness(_ sender: NSMenuItem) {
        manager.damping = Double(sender.tag) / 1000.0
        sender.menu?.items.forEach { $0.state = .off }
        sender.state = .on
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
app.setActivationPolicy(.accessory) // menu bar only, no dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()

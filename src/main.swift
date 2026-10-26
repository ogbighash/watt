// Watt — a menu bar battery companion for Apple Silicon Macs
// -------------------------------------------------------------------
// Watt READS the battery and the screens with Apple's own public tools:
//   - IOKit power sources  -> charge %, charging, plugged in
//   - IORegistry battery   -> health %, cycle count, temperature
//   - CoreGraphics         -> which screens are on
// These reads can change nothing.
//
// Watt changes only two things, and only when you click:
//   - the charge cap, which it does NOT do itself: it asks `batt` (the
//     open-source engine, running as root) to set a number from 10-100
//   - an external screen on/off, via Apple's display configuration
// Watt opens no network connection and keeps no helper. Quit it anytime.

import AppKit
import IOKit
import IOKit.ps
import CoreGraphics
import Foundation
import ServiceManagement

// The version shown in the menu comes from Info.plist (one place to bump).
let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

// The "Buy me a coffee" link in the menu. Empty = no menu item.
let tipURL = "https://creators.sa/en/bighash"

// A plain bag of the numbers we read. No behaviour, just values.
struct Snapshot {
    var percent: Int = -1
    var charging: Bool = false
    var plugged: Bool = false
    var hasBattery: Bool = true  // false on a Mac mini / iMac / Studio
    var healthPercent: Int = -1
    var cycles: Int = -1
    var tempC: Double = 0
    var condition: String = "Unknown"
    var displays: Int = 0
    var displayList: [DisplayInfo] = []
}

// ---- The charge cap is handled by `batt`, the open-source engine ----
// Watt only ASKS batt to read or change the limit. It runs no hardware
// code itself. batt's daemon runs as root (installed once with your
// password); these user-level calls need no password.
// batt is a separate program (GPL-2.0): Watt runs it, never bundles or links it.
let battCandidates = ["/opt/homebrew/bin/batt",   // Homebrew
                      "/usr/local/bin/batt"]      // batt's own install script
let battHomepage = "https://github.com/charlie0129/batt"
let battInstallCommands = "brew install batt\nsudo brew services start batt"
let battStartCommand = "sudo brew services start batt"
let battUpdateCommand = "brew upgrade batt"

// batt only runs on Apple Silicon. Asked at run time, so a copy that was
// built or launched under Rosetta still gets the right answer.
let isAppleSilicon: Bool = {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
}()

func battPath() -> String? {
    battCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

// What the charge-cap part of the menu should say.
enum CapState: Equatable {
    case unsupported     // Intel Mac
    case notInstalled
    case notRunning      // batt is there, but its daemon didn't answer
    case slow            // batt didn't answer in time
    case needsRoot       // batt's daemon only answers to root on this Mac
    case tooOld          // this batt can't report its status as JSON
    case cap(Int)        // the current cap; 100 = off
}

// Run batt with fixed arguments. Never more than `timeout` seconds, so a
// hung daemon can't leave Watt waiting forever.
@discardableResult
func runBatt(_ path: String, _ args: [String],
             timeout: TimeInterval = 10) -> (ok: Bool, output: String, timedOut: Bool) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    // Wait on a semaphore, not waitUntilExit(): that spins the main run loop,
    // which would run timers and alerts in the middle of building the menu.
    let done = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in done.signal() }
    do { try p.run() } catch { return (false, "error: \(error.localizedDescription)", false) }
    let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    let d = pipe.fileHandleForReading.readDataToEndOfFile()   // read before waiting, so a full pipe can't stall
    done.wait()
    killer.cancel()
    let timedOut = p.terminationReason == .uncaughtSignal && p.terminationStatus == SIGTERM
    let ok = p.terminationReason == .exit && p.terminationStatus == 0
    return (ok, String(data: d, encoding: .utf8) ?? "", timedOut)
}

// batt's last line of output, for showing in an alert.
func battMessage(_ output: String) -> String {
    let last = output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
    let text = last.trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? "batt gave no reason." : String(text.prefix(300))
}

// READ ONLY: ask batt's daemon for the current cap. Blocks while batt runs
// (about 15 ms) and never longer than `timeout`.
// batt's config file is deliberately NOT read: a fresh install has none
// until the first change, so the daemon is the only reliable answer.
func readCapState(timeout: TimeInterval = 10) -> CapState {
    guard isAppleSilicon else { return .unsupported }
    guard let path = battPath() else { return .notInstalled }
    let r = runBatt(path, ["status", "--json"], timeout: timeout)
    if r.timedOut { return .slow }
    if !r.ok {
        let out = r.output.lowercased()
        if out.contains("unknown flag") { return .tooOld }
        if out.contains("permission denied") || out.contains("not permitted") { return .needsRoot }
        return .notRunning
    }
    guard let start = r.output.firstIndex(of: "{"),
          let data = String(r.output[start...]).data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let conf = obj["configuration"] as? [String: Any],
          let upper = conf["upperLimitPercent"] as? Int
    else { return .tooOld }
    let enabled = conf["enabled"] as? Bool ?? true
    return .cap(enabled ? min(upper, 100) : 100)
}

// ---- READ ONLY: charge %, charging, plugged in -------------------
// Only the Mac's own battery counts (not a UPS or other power source).
func readPowerSource() -> (Int, Bool, Bool) {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
    else { return (-1, false, false) }

    for ps in list {
        guard let desc = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue()
                as? [String: Any],
              (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
        let cur = desc[kIOPSCurrentCapacityKey] as? Int ?? -1
        let maxv = desc[kIOPSMaxCapacityKey] as? Int ?? 100
        let state = desc[kIOPSPowerSourceStateKey] as? String ?? ""
        let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
        let plugged = (state == kIOPSACPowerValue)
        let pct = maxv > 0 ? Int((Double(cur) / Double(maxv) * 100).rounded()) : cur
        return (pct, charging, plugged)
    }
    return (-1, false, false)
}

// ---- READ ONLY: health %, cycles, temperature, condition ---------
// Returns nil when the Mac has no internal battery.
func readSmartBattery() -> (Int, Int, Double, String)? {
    let svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                          IOServiceMatching("AppleSmartBattery"))
    guard svc != 0 else { return nil }
    defer { IOObjectRelease(svc) }

    var propsRef: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(svc, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let dict = propsRef?.takeRetainedValue() as? [String: Any]
    else { return (-1, -1, 0, "Unknown") }

    let design = dict["DesignCapacity"] as? Int ?? 0
    let maxCap = (dict["AppleRawMaxCapacity"] as? Int) ?? (dict["MaxCapacity"] as? Int) ?? 0
    let cycles = dict["CycleCount"] as? Int ?? -1
    let tempRaw = dict["Temperature"] as? Int ?? 0
    let tempC = Double(tempRaw) / 100.0

    var health = design > 0 ? Int((Double(maxCap) / Double(design) * 100).rounded()) : -1
    if health > 100 { health = 100 }   // match System Settings, which caps at 100%

    let pfs = dict["PermanentFailureStatus"] as? Int ?? 0
    let condition = (pfs == 0) ? "Normal" : "Service recommended"
    return (health, cycles, tempC, condition)
}

// ---- READ ONLY: how many screens are active ----------------------
func readDisplays() -> Int {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    return Int(count)
}

// One online display, described. All reads are public CoreGraphics.
struct DisplayInfo {
    var id: CGDirectDisplayID
    var w: Int
    var h: Int
    var main: Bool
    var builtin: Bool         // the laptop's own screen
    var active: Bool          // drawing right now (false = asleep, mirrored, or turned off)
}

// READ ONLY: every connected display, with size, which is primary, and on/off.
func readDisplayList() -> [DisplayInfo] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &count)
    var out: [DisplayInfo] = []
    for i in 0..<Int(count) {
        let d = ids[i]
        out.append(DisplayInfo(id: d,
                               w: CGDisplayPixelsWide(d),
                               h: CGDisplayPixelsHigh(d),
                               main: CGDisplayIsMain(d) != 0,
                               builtin: CGDisplayIsBuiltin(d) != 0,
                               active: CGDisplayIsActive(d) != 0))
    }
    return out
}

// Turn a display on or off, via Apple's private SkyLight display control.
// HARD GUARDS so it can never black you out:
//   - it will NEVER turn off the main display or the laptop's own screen
//   - it will NEVER turn off the last display that is still on
// Change is "for session": a logout fully restores every display.
func setDisplayEnabled(_ id: CGDirectDisplayID, _ enabled: Bool) -> Bool {
    if !enabled {
        if CGDisplayIsMain(id) != 0 || CGDisplayIsBuiltin(id) != 0 { return false }
        var active: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &active)
        if active <= 1 { return false }                        // never the last screen
    }
    guard let handle = dlopen(nil, RTLD_LAZY),
          let sym = dlsym(handle, "CGSConfigureDisplayEnabled") else { return false }
    typealias Fn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> Int32
    let configureEnabled = unsafeBitCast(sym, to: Fn.self)

    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success else { return false }
    guard configureEnabled(config, id, enabled) == 0 else {
        CGCancelDisplayConfiguration(config)
        return false
    }
    return CGCompleteDisplayConfiguration(config, .forSession) == .success
}

// Watt keeps its small files in ~/Library/Application Support/Watt.
let supportDir: URL = {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Watt")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()

// A turned-off display drops off the online list, so Watt remembers the ones
// it switched off (id -> size) in a small file, and always offers "Turn on".
// The switch only lasts until logout, so the file is stamped with this login
// session (boot ID + audit session) and ignored once a new session starts.
// (The boot ID, unlike the boot time, doesn't move when the clock is corrected.)
let offStateURL = supportDir.appendingPathComponent("off-displays.json")

let sessionKey: String = {
    var info = auditinfo_addr()
    let asid = getaudit_addr(&info, Int32(MemoryLayout<auditinfo_addr>.size)) == 0 ? Int(info.ai_asid) : -1
    var buf = [CChar](repeating: 0, count: 64)
    var size = buf.count
    let boot = sysctlbyname("kern.bootsessionuuid", &buf, &size, nil, 0) == 0
        ? buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } : "unknown"
    return "\(boot)-\(asid)"
}()

func loadOffDisplays() -> [CGDirectDisplayID: String] {
    guard let data = try? Data(contentsOf: offStateURL),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          obj["session"] as? String == sessionKey,
          let off = obj["off"] as? [String: String]
    else { return [:] }
    var out: [CGDirectDisplayID: String] = [:]
    for (k, v) in off { if let id = UInt32(k) { out[id] = v } }
    return out
}

func saveOffDisplays(_ d: [CGDirectDisplayID: String]) {
    var off: [String: String] = [:]
    for (k, v) in d { off["\(k)"] = v }
    let obj: [String: Any] = ["session": sessionKey, "off": off]
    if let data = try? JSONSerialization.data(withJSONObject: obj) {
        try? data.write(to: offStateURL)
    }
}

// ---- Events -> a local log file ------------------------------------
// When something worth knowing happens (battery too hot, charger stopped
// powering the Mac, health dropped, a monitor dropped off), Watt appends
// one JSON line to a log you can watch or script against:
//   ~/Library/Application Support/Watt/events.jsonl
// To write it somewhere else:
//   defaults write com.bighash.watt EventsFile /path/to/events.jsonl
func eventsFileURL() -> URL {
    if let custom = UserDefaults.standard.string(forKey: "EventsFile"), !custom.isEmpty {
        let url = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        // Only if its folder exists (e.g. not a drive that's unmounted right now).
        if FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) {
            return url
        }
    }
    return supportDir.appendingPathComponent("events.jsonl")
}

@discardableResult
func appendEvent(_ type: String, _ message: String) -> Bool {
    let iso = ISO8601DateFormatter().string(from: Date())
    let obj: [String: Any] = ["time": iso, "type": type, "message": message]
    guard var line = try? JSONSerialization.data(withJSONObject: obj) else { return false }
    line.append(0x0A)
    let url = eventsFileURL()
    // The throwing FileHandle calls: a failed write (disk full, drive gone)
    // skips that one line instead of crashing the app.
    do {
        let fh = try FileHandle(forWritingTo: url)
        defer { try? fh.close() }
        _ = try fh.seekToEnd()
        try fh.write(contentsOf: line)
        return true
    } catch {
        // First write creates the file; never overwrites an existing log.
        return (try? line.write(to: url, options: .withoutOverwriting)) != nil
    }
}

func takeSnapshot() -> Snapshot {
    var s = Snapshot()
    (s.percent, s.charging, s.plugged) = readPowerSource()
    if let b = readSmartBattery() {
        (s.healthPercent, s.cycles, s.tempC, s.condition) = b
    } else {
        s.hasBattery = false
    }
    s.displays = readDisplays()
    s.displayList = readDisplayList()
    return s
}

// ---- The menu bar icon (no window, no Dock icon) -----------------
final class Controller: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var timer: Timer?
    var offDisplays: [CGDirectDisplayID: String] = loadOffDisplays()
    // For each "off" record: when this run first saw it (uptime), and whether
    // its screen has actually gone dark since (see reconcileOffDisplays).
    var offSince: [CGDirectDisplayID: TimeInterval] = [:]
    var offWentDark: Set<CGDirectDisplayID> = []

    // A short-lived note ("Copied") shown in the menu for a minute after a click.
    var capNote: (text: String, at: Date)?

    // When batt last timed out (uptime), so a stuck batt can't freeze every menu open.
    var battSlowAt: TimeInterval?

    // Event detection state (edge-triggered, so no repeats every refresh).
    let hotThresholdC = 38.0
    var lastSnap: Snapshot?
    var hotActive = false
    var healthSeen: Int? = UserDefaults.standard.object(forKey: "HealthSeen") as? Int
    var lastExternals: Set<CGDirectDisplayID>?
    var missingSince: [CGDirectDisplayID: TimeInterval] = [:]   // uptime: pauses during sleep

    // The cap "Turn the cap back on" restores (the last one below 100%).
    var lastCap: Int {
        let v = UserDefaults.standard.integer(forKey: "LastCap")
        return (10...99).contains(v) ? v : 80
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        item.button?.title = "…"
        menu.delegate = self
        item.menu = menu
        tick()
        menuNeedsUpdate(menu)
        // Re-read every 30 seconds, and the moment the power source changes.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.tick()
        }
        watchPower()
    }

    // The menu is rebuilt from fresh readings every time it opens. The cap is
    // read right here, not in the background: while a menu is open, macOS holds
    // back work queued for the main thread, so a late answer could never reach
    // it. batt answers in ~15 ms; a hung batt delays the menu by 2 s at most,
    // and then Watt doesn't ask it again for a minute.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let now = ProcessInfo.processInfo.systemUptime
        let cap: CapState
        if let t = battSlowAt, now - t < 60 {
            cap = .slow
        } else {
            cap = readCapState(timeout: 2)
            battSlowAt = (cap == .slow) ? now : nil
        }
        if case .cap(let lim) = cap, lim < 100 {
            UserDefaults.standard.set(lim, forKey: "LastCap")
        }
        populate(cap)
    }

    // Background refresh: readings -> events + icon.
    func tick() {
        let s = takeSnapshot()
        reconcileOffDisplays(s)
        checkEvents(s)
        updateIcon(s)
    }

    // Plug / unplug updates the icon (and the event log) right away.
    func watchPower() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<Controller>.fromOpaque(ctx).takeUnretainedValue().tick()
        }, ctx)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    }

    // Keep the "turned off" list true: pick up changes made from the command
    // line, and forget a screen once it's back on. A record is only dropped
    // after its screen really went dark and came back, or after 30 s if it never
    // went dark: a slow dock can still report "on" right after the click, and
    // dropping the record then would leave the screen off with no "Turn on".
    func reconcileOffDisplays(_ s: Snapshot) {
        let onDisk = loadOffDisplays()
        var merged = offDisplays.merging(onDisk) { mine, _ in mine }
        let now = ProcessInfo.processInfo.systemUptime
        let active = Set(s.displayList.filter { $0.active }.map { $0.id })
        for id in Array(merged.keys) {
            let since = offSince[id] ?? now
            offSince[id] = since
            if !active.contains(id) {
                offWentDark.insert(id)
            } else if offWentDark.contains(id) || now - since > 30 {
                merged.removeValue(forKey: id)
                offSince.removeValue(forKey: id)
                offWentDark.remove(id)
            }
        }
        offDisplays = merged
        if merged != onDisk { saveOffDisplays(merged) }
    }

    func updateIcon(_ s: Snapshot) {
        guard let btn = item.button else { return }
        // Crisp template symbols: they recolour to the menu bar so they
        // stay sharp on any background (unlike the dark plug emoji).
        //   bolt        = charging
        //   plug        = plugged in, not charging (normally: holding at the cap),
        //                 or a Mac with no battery
        //   bolt-slash  = on battery (unplugged)
        let symbolName: String
        let emojiFallback: String
        if s.charging {
            symbolName = "bolt.fill";        emojiFallback = "⚡"
        } else if s.plugged || !s.hasBattery {
            symbolName = "powerplug.fill";   emojiFallback = "🔌"
        } else {
            symbolName = "bolt.slash.fill";  emojiFallback = "🔋"
        }
        let pctText = s.percent >= 0 ? "\(s.percent)%" : (s.hasBattery ? "—" : "")
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Watt") {
            img.isTemplate = true
            btn.image = img
            btn.imagePosition = .imageLeading
            btn.title = pctText.isEmpty ? "" : " \(pctText)"
        } else {
            btn.image = nil
            btn.title = pctText.isEmpty ? emojiFallback : "\(emojiFallback) \(pctText)"
        }
    }

    func populate(_ cap: CapState) {
        let s = takeSnapshot()
        reconcileOffDisplays(s)
        updateIcon(s)
        menu.removeAllItems()

        func line(_ text: String) {
            let mi = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            mi.isEnabled = false
            menu.addItem(mi)
        }
        @discardableResult
        func action(_ title: String, _ sel: Selector, _ obj: Any? = nil, key: String = "") -> NSMenuItem {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            mi.target = self
            mi.representedObject = obj
            menu.addItem(mi)
            return mi
        }

        if s.hasBattery {
            line("Charge: \(s.percent >= 0 ? "\(s.percent)%" : "—")"
                 + (s.charging ? "  (charging)" : s.plugged ? "  (plugged, not charging)" : "  (on battery)"))
            line("Health: \(s.healthPercent >= 0 ? "\(s.healthPercent)%" : "—")  ·  \(s.condition)")
            line("Cycles: \(s.cycles >= 0 ? "\(s.cycles)" : "—")")
            line(s.tempC > 0 ? String(format: "Temperature: %.1f°C", s.tempC) : "Temperature: —")
        } else {
            line("No battery in this Mac — screens only")
        }
        line("Displays: \(s.displays) on")
        var shownIds = Set<CGDirectDisplayID>()
        for d in s.displayList {
            shownIds.insert(d.id)
            let size = "\(d.w)×\(d.h)"
            if d.builtin || d.main {
                line("    • \(d.builtin ? "Built-in" : "Main")  \(size)")    // never switched off
            } else if d.active {
                action("    • External \(size) — Turn off", #selector(toggleDisplay(_:)),
                       ["id": d.id, "on": false, "size": size] as [String: Any])
            } else if offDisplays[d.id] != nil {
                action("    • External \(size) (off) — Turn on", #selector(toggleDisplay(_:)),
                       ["id": d.id, "on": true] as [String: Any])
            } else {
                line("    • External \(size)  (asleep or mirrored)")
            }
        }
        // Screens Watt turned off that dropped off the list entirely: still offer "Turn on".
        for (id, size) in offDisplays where !shownIds.contains(id) {
            let sizeText = size.isEmpty ? "" : "\(size) "
            action("    • External \(sizeText)(off) — Turn on", #selector(toggleDisplay(_:)),
                   ["id": id, "on": true] as [String: Any])
        }

        // ---- Charge cap (handled by batt) ----
        // Battery + screens above work with or without batt.
        if s.hasBattery {
            menu.addItem(.separator())
            switch cap {
            case .unsupported:
                line("Charge cap: needs an Apple Silicon Mac")
            case .notInstalled:
                line("Charge cap: needs batt (free, open source)")
                action("Copy install commands", #selector(copyText(_:)), battInstallCommands)
                action("About batt…", #selector(openLink(_:)), battHomepage)
            case .notRunning:
                line("Charge cap: batt isn't responding")
                if battPath()?.hasPrefix("/opt/homebrew") == true {
                    action("Copy start command", #selector(copyText(_:)), battStartCommand)
                }
                action("About batt…", #selector(openLink(_:)), battHomepage)
            case .slow:
                line("Charge cap: batt is slow to answer")
                action("About batt…", #selector(openLink(_:)), battHomepage)
            case .needsRoot:
                line("Charge cap: batt only answers to root")
                action("About batt…", #selector(openLink(_:)), battHomepage)
            case .tooOld:
                line("Charge cap: batt needs an update")
                if battPath()?.hasPrefix("/opt/homebrew") == true {
                    action("Copy update command", #selector(copyText(_:)), battUpdateCommand)
                } else {
                    action("About batt…", #selector(openLink(_:)), battHomepage)
                }
            case .cap(let lim):
                line(lim >= 100 ? "Charge cap: off  ·  charging to 100%" : "Charge cap: \(lim)%")

                // Submenu to pick the cap.
                let capMenu = NSMenu()
                for value in [60, 70, 75, 80, 85, 90, 100] {
                    let title = value >= 100 ? "100%  (off — full charge)" : "\(value)%"
                    let mi = NSMenuItem(title: title, action: #selector(setLimit(_:)), keyEquivalent: "")
                    mi.target = self
                    mi.representedObject = value
                    mi.state = (value == lim) ? .on : .off
                    capMenu.addItem(mi)
                }
                let capItem = NSMenuItem(title: "Set charge cap", action: nil, keyEquivalent: "")
                capItem.submenu = capMenu
                menu.addItem(capItem)

                // One-tap convenience toggle. 100% stays on until you turn the cap back on.
                if lim >= 100 {
                    action("Turn the cap back on (\(lastCap)%)", #selector(setLimit(_:)), lastCap)
                } else {
                    action("Charge to 100% (turns the cap off)", #selector(setLimit(_:)), 100)
                }
            }
            if let n = capNote, Date().timeIntervalSince(n.at) < 60 { line(n.text) }
        }

        menu.addItem(.separator())
        let login = SMAppService.mainApp.status
        let loginItem = action(login == .requiresApproval ? "Launch at login — approve in System Settings"
                                                          : "Launch at login",
                               #selector(toggleLogin))
        loginItem.state = (login == .enabled) ? .on : .off
        if !tipURL.isEmpty {
            action("Buy me a coffee ☕", #selector(openLink(_:)), tipURL)
        }

        menu.addItem(.separator())
        line("Watt \(appVersion)")
        menu.addItem(NSMenuItem(title: "Quit Watt",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // Edge-triggered event detection. Each event fires once on the change,
    // not every refresh. Events are appended to the local log (see eventsFileURL).
    func checkEvents(_ s: Snapshot) {
        // 1) Too hot (with hysteresis so it doesn't flap on the threshold).
        if s.tempC >= hotThresholdC && !hotActive {
            hotActive = true
            appendEvent("hot", String(format: "Battery is hot: %.1f°C", s.tempC))
        } else if s.tempC < hotThresholdC - 2 && hotActive {
            hotActive = false
        }

        // 2) Battery health dropped (remembered across restarts; started over
        //    if the cycle count goes down, i.e. the battery was replaced).
        let defaults = UserDefaults.standard
        if s.cycles >= 0 {
            if let c = defaults.object(forKey: "HealthCycles") as? Int, s.cycles < c { healthSeen = nil }
            defaults.set(s.cycles, forKey: "HealthCycles")
        }
        if let seen = healthSeen {
            if s.healthPercent >= 0 && s.healthPercent < seen {
                appendEvent("health", "Battery health dropped to \(s.healthPercent)% (was \(seen)%)")
                healthSeen = s.healthPercent
                UserDefaults.standard.set(s.healthPercent, forKey: "HealthSeen")
            }
        } else if s.healthPercent >= 0 {
            healthSeen = s.healthPercent
            UserDefaults.standard.set(s.healthPercent, forKey: "HealthSeen")
        }

        // 3) Charger stopped powering the Mac (was on wall power, now not).
        if let last = lastSnap, last.plugged && !s.plugged {
            appendEvent("power", "Charger stopped powering the Mac — now on battery")
        }

        // 4) A monitor dropped off that WE didn't turn off. Compared by display ID,
        //    ignoring the laptop's own screen (closing the lid isn't a drop), and
        //    only logged if it's still gone 20 s later (waking from sleep, a wiggle).
        let externals = Set(s.displayList.filter { !$0.builtin }.map { $0.id })
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastExternals {
            for id in last.subtracting(externals) where offDisplays[id] == nil && missingSince[id] == nil {
                missingSince[id] = now
            }
        }
        for id in Array(missingSince.keys) {
            if externals.contains(id) || offDisplays[id] != nil {
                missingSince.removeValue(forKey: id)
            } else if let since = missingSince[id], now - since >= 20 {
                appendEvent("display", "A monitor dropped off — \(s.displays) screen\(s.displays == 1 ? "" : "s") on now")
                missingSince.removeValue(forKey: id)
            }
        }
        lastExternals = externals
        lastSnap = s
    }

    // Shown when a click couldn't do what it said.
    func showProblem(_ title: String, _ detail: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }

    // Ask batt to change the cap, off the main thread. The menu reads the new
    // cap the next time it opens.
    @objc func setLimit(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Int, let path = battPath() else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = runBatt(path, ["limit", "\(value)"])
            guard !result.ok else { return }
            let reason = result.timedOut ? "batt didn't answer within 10 seconds." : battMessage(result.output)
            DispatchQueue.main.async {
                self?.showProblem("batt couldn't set the cap to \(value)%",
                                  reason + "\n\nSee Troubleshooting in Watt's README.")
            }
        }
    }

    // Turn a display on/off (guards live inside setDisplayEnabled).
    @objc func toggleDisplay(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let id = info["id"] as? CGDirectDisplayID,
              let on = info["on"] as? Bool else { return }
        if on {
            // The "off" record is dropped once the screen shows up again (reconcileOffDisplays).
            if !setDisplayEnabled(id, true) {
                showProblem("Couldn't turn that screen back on",
                            "If it's unplugged, plug it back in. Logging out and back in always brings every screen back.")
            }
        } else if setDisplayEnabled(id, false) {
            offDisplays[id] = (info["size"] as? String) ?? ""   // recorded first: not a "dropped" monitor
            offSince[id] = ProcessInfo.processInfo.systemUptime
            offWentDark.remove(id)
            saveOffDisplays(offDisplays)
        }
        tick()
    }

    // Register / unregister Watt as a login item (System Settings › General › Login Items).
    @objc func toggleLogin() {
        let login = SMAppService.mainApp
        do {
            switch login.status {
            case .enabled:          try login.unregister()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
            default:                try login.register()
            }
        } catch {
            showProblem("Couldn't change Launch at login", error.localizedDescription)
        }
    }

    // Put a Terminal command on the clipboard (for setting up batt).
    @objc func copyText(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        capNote = ("✓ Copied — paste it into Terminal", Date())
    }

    @objc func openLink(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String, let url = URL(string: s) else { return }
        NSWorkspace.shared.open(url)
    }
}

// Headless check: `Watt --print` runs the exact same read code once,
// prints the numbers, and exits. No menu bar, no window. Lets you
// sanity-check the readings from Terminal before trusting the icon.
if CommandLine.arguments.contains("--print") {
    let s = takeSnapshot()
    print("watt:     \(appVersion)")
    if s.hasBattery {
        print("charge:   \(s.percent)%  (\(s.charging ? "charging" : s.plugged ? "plugged, not charging" : "on battery"))")
        print("health:   \(s.healthPercent)%  ·  \(s.condition)")
        print("cycles:   \(s.cycles)")
        print(String(format: "temp:     %.1f C", s.tempC))
        switch readCapState() {
        case .cap(let lim):  print("cap:      \(lim >= 100 ? "off (100%)" : "\(lim)%")")
        case .unsupported:   print("cap:      needs an Apple Silicon Mac")
        case .notInstalled:  print("cap:      batt not installed")
        case .notRunning:    print("cap:      batt not responding")
        case .slow:          print("cap:      batt didn't answer in time")
        case .needsRoot:     print("cap:      batt only answers to root")
        case .tooOld:        print("cap:      batt needs an update")
        }
    } else {
        print("battery:  none (screens only)")
    }
    print("screens:  \(s.displays)")
    for d in s.displayList {
        let kind = d.builtin ? "built-in" : d.main ? "main" : "ext"
        print("   - \(kind.padding(toLength: 9, withPad: " ", startingAt: 0))\(d.active ? "\(d.w)x\(d.h)" : "not drawing")  id=\(d.id)")
    }
    exit(0)
}

// Hidden CLI: `Watt --set-display <id> <0|1>` runs the SAME guarded toggle the
// menu uses, so it can be verified from Terminal. 0 = off, 1 = on.
if let i = CommandLine.arguments.firstIndex(of: "--set-display"),
   i + 2 < CommandLine.arguments.count,
   let id = UInt32(CommandLine.arguments[i + 1]),
   let on = Int(CommandLine.arguments[i + 2]) {
    let w = CGDisplayPixelsWide(id), h = CGDisplayPixelsHigh(id)
    let ok = setDisplayEnabled(id, on != 0)
    if ok && on == 0 {
        var off = loadOffDisplays()
        off[id] = "\(w)×\(h)"
        saveOffDisplays(off)
    }
    print("set-display id=\(id) on=\(on != 0) -> \(ok ? "ok" : "refused")")
    exit(ok ? 0 : 1)
}

// Hidden: `Watt --emit-test-event` writes one test event, to check the log.
if CommandLine.arguments.contains("--emit-test-event") {
    let ok = appendEvent("test", "Test event from Watt")
    print(ok ? "emitted test event to \(eventsFileURL().path)"
             : "could not write to \(eventsFileURL().path)")
    exit(ok ? 0 : 1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu bar only: no Dock icon, no window
let controller = Controller()
app.delegate = controller
app.run()

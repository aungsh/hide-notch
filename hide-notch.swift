// hide-notch: paints a black strip over the top of the wallpaper on notched
// screens so the menu bar (and the notch) look solid black.
//
// Usage: hide-notch apply | restore | status | watch
import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - State

let appDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/hide-notch")
let statePath = appDir.appendingPathComponent("state.json")

/// Original wallpaper settings for one display, so `restore` can put them back.
struct Saved: Codable {
    var path: String
    var scaling: UInt
    var clipping: Bool
}
typealias State = [String: Saved]

/// Radius (points) of the inverted corners under the black bar. 0 disables them.
let radiusPath = appDir.appendingPathComponent("radius")
let defaultRadius: CGFloat = 16

func loadRadius() -> CGFloat {
    guard let s = try? String(contentsOf: radiusPath, encoding: .utf8),
          let v = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)), v >= 0 else { return defaultRadius }
    return CGFloat(v)
}

func saveRadius(_ r: CGFloat) {
    try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
    try? "\(Double(r))".write(to: radiusPath, atomically: true, encoding: .utf8)
}

func loadState() -> State {
    guard let data = try? Data(contentsOf: statePath),
          let s = try? JSONDecoder().decode(State.self, from: data) else { return [:] }
    return s
}

func saveState(_ s: State) {
    try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(s) { try? data.write(to: statePath, options: .atomic) }
}

// MARK: - Helpers

struct Failure: Error, CustomStringConvertible { let description: String }

func displayKey(_ screen: NSScreen) -> String {
    guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
          let uuid = CGDisplayCreateUUIDFromDisplayID(num.uint32Value)?.takeRetainedValue(),
          let str = CFUUIDCreateString(nil, uuid) as String? else { return "unknown" }
    return str
}

func isOurs(_ url: URL) -> Bool { url.path.hasPrefix(appDir.path) }

func fnv(_ s: String) -> String {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    return String(h, radix: 16)
}

func generatedFiles(for key: String) -> [URL] {
    let items = (try? FileManager.default.contentsOfDirectory(at: appDir, includingPropertiesForKeys: nil)) ?? []
    return items.filter { $0.lastPathComponent.hasPrefix(key + "-") }
}

// MARK: - Rendering

func render(original: Saved, pixelW: Int, pixelH: Int, stripPx: Int, radiusPx: Int, to out: URL) throws {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: original.path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        throw Failure(description: "cannot read wallpaper image at \(original.path)")
    }
    let cs = CGColorSpace(name: CGColorSpace.displayP3)!
    guard let ctx = CGContext(data: nil, width: pixelW, height: pixelH, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        throw Failure(description: "cannot create bitmap context")
    }
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
    ctx.interpolationQuality = .high

    let iw = CGFloat(img.width), ih = CGFloat(img.height)
    let sw = CGFloat(pixelW), sh = CGFloat(pixelH)
    let dest: CGRect
    switch NSImageScaling(rawValue: original.scaling) ?? .scaleProportionallyUpOrDown {
    case .scaleAxesIndependently:
        dest = CGRect(x: 0, y: 0, width: sw, height: sh)
    case .scaleNone:
        dest = CGRect(x: (sw - iw) / 2, y: (sh - ih) / 2, width: iw, height: ih)
    case .scaleProportionallyDown, .scaleProportionallyUpOrDown:
        let fill = original.clipping
        var scale = fill ? max(sw / iw, sh / ih) : min(sw / iw, sh / ih)
        if NSImageScaling(rawValue: original.scaling) == .scaleProportionallyDown { scale = min(scale, 1) }
        let w = iw * scale, h = ih * scale
        dest = CGRect(x: (sw - w) / 2, y: (sh - h) / 2, width: w, height: h)
    @unknown default:
        dest = CGRect(x: 0, y: 0, width: sw, height: sh)
    }
    ctx.draw(img, in: dest)

    // CGContext origin is bottom-left, so the top strip starts at y = height - strip.
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: pixelH - stripPx, width: pixelW, height: stripPx))

    // Inverted corners: black fillets under both ends of the bar, so the screen
    // content below looks like a rounded rectangle and window corners meet it cleanly.
    if radiusPx > 0 {
        let r = CGFloat(radiusPx)
        let top = CGFloat(pixelH - stripPx)
        let bottom = top - r
        ctx.beginPath()
        ctx.move(to: CGPoint(x: 0, y: top))
        ctx.addLine(to: CGPoint(x: r, y: top))
        ctx.addArc(center: CGPoint(x: r, y: bottom), radius: r, startAngle: .pi / 2, endAngle: .pi, clockwise: false)
        ctx.closePath()
        ctx.move(to: CGPoint(x: sw, y: top))
        ctx.addLine(to: CGPoint(x: sw - r, y: top))
        ctx.addArc(center: CGPoint(x: sw - r, y: bottom), radius: r, startAngle: .pi / 2, endAngle: 0, clockwise: true)
        ctx.closePath()
        ctx.fillPath()
    }

    guard let result = ctx.makeImage(),
          let dst = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw Failure(description: "cannot create output image")
    }
    CGImageDestinationAddImage(dst, result, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
    guard CGImageDestinationFinalize(dst) else { throw Failure(description: "cannot write \(out.path)") }
}

// MARK: - Apply / restore

/// Returns true if the wallpaper was changed.
@discardableResult
func apply(_ screen: NSScreen, state: inout State) throws -> Bool {
    let strip = screen.safeAreaInsets.top
    guard strip > 0 else { return false }
    let ws = NSWorkspace.shared
    let key = displayKey(screen)
    guard let current = ws.desktopImageURL(for: screen) else { throw Failure(description: "no wallpaper URL") }

    let original: Saved
    if isOurs(current) {
        guard let saved = state[key] else {
            throw Failure(description: "wallpaper is a generated file but no original is recorded; set your wallpaper again")
        }
        original = saved
    } else {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: current.path, isDirectory: &isDir), !isDir.boolValue else {
            throw Failure(description: "wallpaper is a folder (shuffle) or missing; only a single static image is supported")
        }
        let opts = ws.desktopImageOptions(for: screen) ?? [:]
        original = Saved(
            path: current.path,
            scaling: (opts[.imageScaling] as? NSNumber)?.uintValue ?? NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            clipping: (opts[.allowClipping] as? NSNumber)?.boolValue ?? true)
    }

    let scale = screen.backingScaleFactor
    let pw = Int((screen.frame.width * scale).rounded())
    let ph = Int((screen.frame.height * scale).rounded())
    let sp = Int((strip * scale).rounded())
    let mtime = (try? FileManager.default.attributesOfItem(atPath: original.path)[.modificationDate] as? Date)?
        .timeIntervalSince1970 ?? 0
    let rp = Int((loadRadius() * scale).rounded())
    let tag = fnv("\(original.path)|\(mtime)|\(original.scaling)|\(original.clipping)|\(sp)|\(rp)")
    let name = "\(key)-\(pw)x\(ph)-\(tag).jpg"
    if current.lastPathComponent == name { return false }

    try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
    let out = appDir.appendingPathComponent(name)
    try render(original: original, pixelW: pw, pixelH: ph, stripPx: sp, radiusPx: rp, to: out)
    try ws.setDesktopImageURL(out, for: screen, options: [
        .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
        .allowClipping: true,
    ])
    state[key] = original
    saveState(state)
    for old in generatedFiles(for: key) where old != out { try? FileManager.default.removeItem(at: old) }
    return true
}

func restoreAll() {
    var state = loadState()
    for screen in NSScreen.screens {
        let key = displayKey(screen)
        guard let saved = state[key] else { continue }
        let url = URL(fileURLWithPath: saved.path)
        do {
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [
                .imageScaling: saved.scaling,
                .allowClipping: saved.clipping,
            ])
            for f in generatedFiles(for: key) { try? FileManager.default.removeItem(at: f) }
            state[key] = nil
            print("restored \(url.lastPathComponent)")
        } catch {
            fputs("restore failed for \(key): \(error)\n", stderr)
        }
    }
    saveState(state)
}

func applyAll(quiet: Bool = false) {
    var state = loadState()
    for screen in NSScreen.screens {
        do {
            let changed = try apply(screen, state: &state)
            if !quiet { print("\(screen.localizedName): " + (changed ? "applied" : "ok (no change)")) }
        } catch {
            fputs("\(screen.localizedName): \(error)\n", stderr)
        }
    }
}

func status() {
    let state = loadState()
    for screen in NSScreen.screens {
        let inset = screen.safeAreaInsets.top
        let cur = NSWorkspace.shared.desktopImageURL(for: screen)?.lastPathComponent ?? "?"
        let on = state[displayKey(screen)] != nil
        print("\(screen.localizedName): notch=\(inset > 0 ? "yes (\(Int(inset))pt)" : "no") hidden=\(on) wallpaper=\(cur)")
    }
}

// MARK: - Watch (event-driven, no polling)

func watch() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    var pending: DispatchWorkItem?
    let schedule = {
        pending?.cancel()
        let w = DispatchWorkItem { applyAll(quiet: true) }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
    }
    NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                           object: nil, queue: .main) { _ in schedule() }
    let wsc = NSWorkspace.shared.notificationCenter
    wsc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in schedule() }
    wsc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in schedule() }
    applyAll(quiet: true)
    app.run()
    exit(0)
}

// MARK: - LaunchAgent (on / off)

let agentLabel = "local.hide-notch"
let agentPlist = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")

@discardableResult
func launchctl(_ args: String...) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = args
    p.standardError = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

func turnOn() {
    guard let exe = Bundle.main.executablePath else { fputs("cannot resolve executable path\n", stderr); exit(1) }
    let plist: [String: Any] = [
        "Label": agentLabel,
        "ProgramArguments": [exe, "watch"],
        "RunAtLoad": true,
        "KeepAlive": true,
        "ProcessType": "Background",
        "LowPriorityIO": true,
    ]
    do {
        try FileManager.default.createDirectory(at: agentPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: agentPlist, options: .atomic)
    } catch {
        fputs("cannot write \(agentPlist.path): \(error)\n", stderr); exit(1)
    }
    let domain = "gui/\(getuid())"
    launchctl("bootout", "\(domain)/\(agentLabel)")
    if launchctl("bootstrap", domain, agentPlist.path) != 0 {
        fputs("launchctl bootstrap failed\n", stderr); exit(1)
    }
    print("on: watcher running as \(agentLabel) (starts at login)")
}

func turnOff() {
    launchctl("bootout", "gui/\(getuid())/\(agentLabel)")
    try? FileManager.default.removeItem(at: agentPlist)
    restoreAll()
    print("off: watcher stopped, wallpaper restored")
}

// MARK: - Main

switch CommandLine.arguments.dropFirst().first {
case "on": turnOn()
case "off": turnOff()
case "radius":
    guard CommandLine.arguments.count > 2, let v = Double(CommandLine.arguments[2]), v >= 0, v <= 100 else {
        print("corner radius: \(Int(loadRadius()))pt (usage: hide-notch radius <0-100>)")
        exit(0)
    }
    saveRadius(CGFloat(v))
    if loadState().isEmpty { print("saved; takes effect on next `hide-notch on`") } else { applyAll() }
case "apply": applyAll()
case "restore": restoreAll()
case "status": status()
case "watch": watch()
default:
    fputs("""
    usage: hide-notch <command>
      on       hide the notch now and keep it hidden (LaunchAgent, starts at login)
      off      stop the watcher and restore the original wallpaper
      status   show per-display state
      radius N corner radius in points under the bar (default 16, 0 = none)
      apply    one-shot apply, no watcher
      restore  one-shot restore, no watcher
      watch    run the watcher in the foreground\n
    """, stderr)
    exit(64)
}

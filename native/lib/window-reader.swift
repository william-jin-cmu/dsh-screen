// Reading a window through the macOS Accessibility API. Compiled into each helper that declares
// `// uses: shared/swift/window-reader.swift` (scripts/build.mjs puts it ahead of the helper's source).

import Cocoa
import ApplicationServices

// MARK: - Accessibility reads

func axValue(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
    return value
}

func axString(_ el: AXUIElement, _ attr: String) -> String? {
    guard let value = axValue(el, attr) else { return nil }
    if let s = value as? String { return s }
    if let url = value as? URL { return url.absoluteString }
    return nil
}

func axElement(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
    guard let value = axValue(el, attr), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func axChildren(_ el: AXUIElement) -> [AXUIElement] {
    (axValue(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

struct Snapshot {
    var app = ""
    var bundle = ""
    var pid: pid_t = 0
    var title = ""
    var url = ""
    var selected = ""
    var text = ""
    var truncated = false
}

let browserBundles: Set<String> = [
    "com.google.Chrome", "com.google.Chrome.canary", "com.apple.Safari", "com.microsoft.edgemac",
    "company.thebrowser.Browser", "com.brave.Browser", "org.mozilla.firefox", "com.vivaldi.Vivaldi",
    "com.operasoftware.Opera", "org.chromium.Chromium", "com.kagi.kagimacOS", "company.thebrowser.dia",
]

/// Walks a window's accessibility tree and collects readable text, bounded by nodes, characters and time.
func readWindow(_ window: AXUIElement, maxChars: Int, deadline: Date) -> (text: String, url: String, truncated: Bool) {
    var lines: [String] = []
    var seen = Set<String>()
    var chars = 0
    var url = ""
    var truncated = false
    var queue: [(AXUIElement, Int)] = [(window, 0)]
    var visited = 0
    // Depth-first in document order so the text reads top to bottom.
    while let (el, depth) = queue.popLast() {
        visited += 1
        if visited > 6000 || chars >= maxChars || Date() > deadline { truncated = true; break }
        let role = axString(el, kAXRoleAttribute as String) ?? ""
        if role == "AXSecureTextField" { continue }
        if role == "AXWebArea", url.isEmpty, let u = axString(el, "AXURL") { url = u }
        var piece: String?
        switch role {
        case "AXStaticText", "AXTextArea", "AXTextField", "AXComboBox":
            piece = axString(el, kAXValueAttribute as String)
            if (piece ?? "").isEmpty, role == "AXStaticText" { piece = axString(el, kAXTitleAttribute as String) }
        case "AXHeading", "AXLink", "AXButton", "AXMenuButton", "AXPopUpButton", "AXCell", "AXRow":
            piece = axString(el, kAXTitleAttribute as String)
            if (piece ?? "").isEmpty { piece = axString(el, kAXDescriptionAttribute as String) }
        case "AXImage":
            piece = axString(el, kAXDescriptionAttribute as String)
        default:
            break
        }
        if let raw = piece {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty, line.count > 1 || role == "AXStaticText", !seen.contains(line) {
                seen.insert(line)
                let room = maxChars - chars
                if line.count > room { lines.append(String(line.prefix(room))); chars = maxChars; truncated = true; break }
                lines.append(line)
                chars += line.count + 1
            }
        }
        // A text container's value already holds its children's text.
        if role == "AXTextArea" || role == "AXTextField" || role == "AXStaticText" { continue }
        if depth < 60 {
            for child in axChildren(el).reversed() { queue.append((child, depth + 1)) }
        }
    }
    return (lines.joined(separator: "\n"), url, truncated)
}

func snapshot(pid: pid_t, maxChars: Int, budgetMs: Int) -> Snapshot? {
    guard let running = NSRunningApplication(processIdentifier: pid) else { return nil }
    var snap = Snapshot()
    snap.pid = pid
    snap.app = running.localizedName ?? ""
    snap.bundle = running.bundleIdentifier ?? ""
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.4)
    // Chromium and Electron build their accessibility tree only when asked.
    AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    if browserBundles.contains(snap.bundle) {
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }
    guard let window = axElement(app, kAXFocusedWindowAttribute as String) ?? axElement(app, kAXMainWindowAttribute as String) else {
        return snap
    }
    snap.title = axString(window, kAXTitleAttribute as String) ?? ""
    if let focused = axElement(app, kAXFocusedUIElementAttribute as String),
       axString(focused, kAXRoleAttribute as String) != "AXSecureTextField" {
        snap.selected = String((axString(focused, kAXSelectedTextAttribute as String) ?? "").prefix(4000))
    }
    let read = readWindow(window, maxChars: maxChars, deadline: Date().addingTimeInterval(Double(budgetMs) / 1000))
    snap.text = read.text
    snap.truncated = read.truncated
    snap.url = read.url.isEmpty ? (axString(window, kAXDocumentAttribute as String) ?? "") : read.url
    return snap
}

/// Pids of apps with a normal on-screen window, front to back.
func pidsFrontToBack() -> [pid_t] {
    var pids: [pid_t] = []
    if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier { pids.append(front) }
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    for info in list {
        guard (info[kCGWindowLayer as String] as? Int) == 0, let pid = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
        if !pids.contains(pid) { pids.append(pid) }
    }
    return pids
}

func frontWindowID(pid: pid_t) -> CGWindowID? {
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    for info in list where (info[kCGWindowLayer as String] as? Int) == 0 && (info[kCGWindowOwnerPID as String] as? pid_t) == pid {
        if let id = info[kCGWindowNumber as String] as? CGWindowID { return id }
    }
    return nil
}

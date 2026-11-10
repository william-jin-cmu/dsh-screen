// dsh-screen helper: reads what is on the user's screen through the macOS Accessibility API.
//
//   dsh-screen-helper permcheck
//       -> {"accessibility":true,"screenRecording":false}          (no prompts)
//   dsh-screen-helper serve --db <path> [--memory] [--interval <s>] [--retention-days <n>]
//                           [--ignore-bundle <id>]... [--ignore-url <prefix>]... [--exclude-bundle <id>]...
//       -> JSON lines on stdin, one JSON line back per request:
//            {"id":1,"op":"now","shot":"/tmp/x.png"?}   the window the user is looking at
//            {"id":2,"op":"status"}                      collector state + data span
//            {"id":3,"op":"timeline","fromMs":..,"toMs":..,"app":"..."?,"text":true?}
//            {"id":4,"op":"search","query":"..","fromMs":..?,"toMs":..?,"app":".."?,"limit":10?}
//            {"id":5,"op":"get","entry":123}
//            {"id":6,"op":"ignore","urls":["http://127.0.0.1:3080"]}   add URL prefixes to ignore
//          Exits on stdin EOF.
//
// "Ignored" apps and URL prefixes are DSH's own surfaces (the desktop app, the web UI tab): when one of them is
// frontmost, `now` reports the next window down instead, so switching to the chat does not hide what the user was
// looking at. "Excluded" apps are never read at all (password managers).
//
// With --memory the helper samples the frontmost window every --interval seconds and keeps its text in SQLite
// (FTS5 trigram index) so `timeline` and `search` can answer "what was I doing". Nothing leaves the machine.

import Cocoa
import ApplicationServices
import SQLite3

// uses: native/lib/window-reader.swift

// MARK: - Output

let outLock = NSLock()
func emit(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
    outLock.lock()
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    outLock.unlock()
}

func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

// MARK: - Options

struct Options {
    var db = ""
    var memory = false
    var interval = 5.0
    var retentionDays = 30
    var ignoreBundles = Set<String>()
    var ignoreURLs: [String] = []
    var excludeBundles = Set<String>()
}

var options = Options()

/// A set entry ending in `*` matches by prefix (the DSH desktop app's bundle id carries a per-build suffix).
func matches(_ bundle: String, _ set: Set<String>) -> Bool {
    if set.contains(bundle) { return true }
    return set.contains { $0.hasSuffix("*") && bundle.hasPrefix($0.dropLast()) }
}

func isIgnored(_ snap: Snapshot) -> Bool {
    if matches(snap.bundle, options.ignoreBundles) { return true }
    return !snap.url.isEmpty && options.ignoreURLs.contains { snap.url.hasPrefix($0) }
}

/// The window the user is looking at: the frontmost one that is not DSH itself and not excluded.
func currentWindow(maxChars: Int, budgetMs: Int) -> (Snapshot?, skipped: [String]) {
    var skipped: [String] = []
    for pid in pidsFrontToBack().prefix(4) {
        guard let running = NSRunningApplication(processIdentifier: pid) else { continue }
        let bundle = running.bundleIdentifier ?? ""
        if matches(bundle, options.excludeBundles) { skipped.append(running.localizedName ?? bundle); continue }
        if matches(bundle, options.ignoreBundles) { skipped.append(running.localizedName ?? bundle); continue }
        guard let snap = snapshot(pid: pid, maxChars: maxChars, budgetMs: budgetMs) else { continue }
        if isIgnored(snap) { skipped.append(snap.app); continue }
        return (snap, skipped)
    }
    return (nil, skipped)
}

// MARK: - Store

final class Store {
    var db: OpaquePointer?

    init?(path: String) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard sqlite3_open(path, &db) == SQLITE_OK else { return nil }
        exec("PRAGMA journal_mode=WAL")
        exec("""
        CREATE TABLE IF NOT EXISTS spans(
          id INTEGER PRIMARY KEY, app TEXT NOT NULL, bundle TEXT NOT NULL, title TEXT NOT NULL, url TEXT NOT NULL,
          start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS spans_start ON spans(start_ms);
        CREATE TABLE IF NOT EXISTS entries(
          id INTEGER PRIMARY KEY, span_id INTEGER NOT NULL, ts_ms INTEGER NOT NULL, text TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS entries_span ON entries(span_id);
        CREATE VIRTUAL TABLE IF NOT EXISTS entries_fts USING fts5(text, content='entries', content_rowid='id', tokenize='trigram');
        CREATE TRIGGER IF NOT EXISTS entries_ai AFTER INSERT ON entries BEGIN
          INSERT INTO entries_fts(rowid, text) VALUES (new.id, new.text); END;
        CREATE TRIGGER IF NOT EXISTS entries_ad AFTER DELETE ON entries BEGIN
          INSERT INTO entries_fts(entries_fts, rowid, text) VALUES ('delete', old.id, old.text); END;
        """)
    }

    @discardableResult func exec(_ sql: String) -> Bool { sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK }

    func query(_ sql: String, _ args: [Any] = []) -> [[String: Any]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            FileHandle.standardError.write("sqlite: \(String(cString: sqlite3_errmsg(db)))\n".data(using: .utf8)!)
            return []
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, arg) in args.enumerated() {
            let n = Int32(i + 1)
            if let v = arg as? Int64 { sqlite3_bind_int64(stmt, n, v) }
            else if let v = arg as? Int { sqlite3_bind_int64(stmt, n, Int64(v)) }
            else if let v = arg as? String { sqlite3_bind_text(stmt, n, v, -1, transient) }
            else { sqlite3_bind_null(stmt, n) }
        }
        var rows: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(stmt, c)
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, c)
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(stmt, c))
                default: break
                }
            }
            rows.append(row)
        }
        return rows
    }

    func prune(retentionDays: Int) {
        let cutoff = nowMs() - Int64(retentionDays) * 86_400_000
        _ = query("DELETE FROM entries WHERE ts_ms < ?", [cutoff])
        _ = query("DELETE FROM spans WHERE end_ms < ?", [cutoff])
    }
}

// MARK: - Collector

final class Collector {
    let store: Store
    var timer: Timer?
    var spanID: Int64 = 0
    var spanKey = ""
    var lastSampleMs: Int64 = 0
    var lastText = ""
    var samples = 0

    init(store: Store) { self.store = store }

    func start(interval: Double) {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.sample() }
        sample()
    }

    func sample() {
        // No input for a while means nobody is looking: close the open span instead of stretching it.
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle > 120 { spanKey = ""; return }
        let (found, _) = currentWindow(maxChars: 8000, budgetMs: 250)
        guard let snap = found, !snap.bundle.isEmpty else { spanKey = ""; return }
        let now = nowMs()
        let key = "\(snap.bundle)\u{1}\(snap.title)\u{1}\(snap.url)"
        // A gap longer than three intervals (sleep, lock) also starts a new span.
        if key == spanKey, now - lastSampleMs < Int64(options.interval * 3000) + 2000 {
            _ = store.query("UPDATE spans SET end_ms = ? WHERE id = ?", [now, spanID])
        } else {
            _ = store.query("INSERT INTO spans(app, bundle, title, url, start_ms, end_ms) VALUES (?,?,?,?,?,?)",
                            [snap.app, snap.bundle, snap.title, snap.url, now, now])
            spanID = sqlite3_last_insert_rowid(store.db)
            spanKey = key
            lastText = ""
        }
        lastSampleMs = now
        samples += 1
        if !snap.text.isEmpty, snap.text != lastText {
            _ = store.query("INSERT INTO entries(span_id, ts_ms, text) VALUES (?,?,?)", [spanID, now, snap.text])
            lastText = snap.text
        }
    }
}

// MARK: - Requests

func ftsQuery(_ words: String) -> String {
    // Each term quoted so punctuation is literal; trigram needs three characters per term.
    words.split(whereSeparator: { $0 == " " || $0 == "\t" })
        .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        .joined(separator: " ")
}

func excerpt(_ text: String, around query: String, radius: Int = 140) -> String {
    let flat = text.replacingOccurrences(of: "\n", with: " ⏎ ")
    let needle = query.split(separator: " ").first.map(String.init) ?? query
    guard let range = flat.range(of: needle, options: .caseInsensitive) else { return String(flat.prefix(radius * 2)) }
    let start = flat.index(range.lowerBound, offsetBy: -radius, limitedBy: flat.startIndex) ?? flat.startIndex
    let end = flat.index(range.upperBound, offsetBy: radius, limitedBy: flat.endIndex) ?? flat.endIndex
    return (start > flat.startIndex ? "…" : "") + String(flat[start..<end]) + (end < flat.endIndex ? "…" : "")
}

func handle(_ req: [String: Any], store: Store?, collector: Collector?) -> [String: Any] {
    let op = req["op"] as? String ?? ""
    func int(_ key: String) -> Int64? { (req[key] as? NSNumber)?.int64Value }
    switch op {
    case "ignore":
        for url in (req["urls"] as? [String]) ?? [] where !options.ignoreURLs.contains(url) { options.ignoreURLs.append(url) }
        return ["ok": true, "result": ["ignoreURLs": options.ignoreURLs]]
    case "now":
        guard AXIsProcessTrusted() else { return ["ok": false, "error": "accessibility_denied"] }
        let maxChars = Int(int("maxChars") ?? 12000)
        // An explicit pid reads that app's focused window (for debugging); otherwise the frontmost one.
        let (found, skipped) = int("pid").map { (snapshot(pid: pid_t($0), maxChars: maxChars, budgetMs: 700), [String]()) }
            ?? currentWindow(maxChars: maxChars, budgetMs: 700)
        guard let snap = found else { return ["ok": false, "error": "no_window", "skipped": skipped] }
        var result: [String: Any] = [
            "app": snap.app, "bundle": snap.bundle, "title": snap.title, "url": snap.url,
            "selected": snap.selected, "text": snap.text, "truncated": snap.truncated, "skipped": skipped,
        ]
        if let shot = req["shot"] as? String, !shot.isEmpty {
            if !CGPreflightScreenCaptureAccess() {
                result["shotError"] = "screen_recording_denied"
            } else if let id = frontWindowID(pid: snap.pid) {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                task.arguments = ["-x", "-o", "-l", String(id), shot]
                try? task.run()
                task.waitUntilExit()
                if FileManager.default.fileExists(atPath: shot) { result["shot"] = shot } else { result["shotError"] = "capture_failed" }
            } else {
                result["shotError"] = "no_window_id"
            }
        }
        return ["ok": true, "result": result]
    case "status":
        var result: [String: Any] = [
            "accessibility": AXIsProcessTrusted(), "screenRecording": CGPreflightScreenCaptureAccess(),
            "memory": collector != nil, "intervalSeconds": options.interval, "retentionDays": options.retentionDays,
        ]
        if let store = store, let row = store.query("SELECT MIN(start_ms) AS first, MAX(end_ms) AS last, COUNT(*) AS spans FROM spans").first {
            result["firstMs"] = row["first"] ?? NSNull()
            result["lastMs"] = row["last"] ?? NSNull()
            result["spans"] = row["spans"] ?? 0
            result["entries"] = store.query("SELECT COUNT(*) AS n FROM entries").first?["n"] ?? 0
        }
        return ["ok": true, "result": result]
    case "timeline":
        guard let store = store else { return ["ok": false, "error": "no_store"] }
        let from = int("fromMs") ?? 0
        let to = int("toMs") ?? nowMs()
        var sql = "SELECT id, app, bundle, title, url, start_ms, end_ms FROM spans WHERE end_ms >= ? AND start_ms <= ?"
        var args: [Any] = [from, to]
        if let app = req["app"] as? String, !app.isEmpty {
            sql += " AND (app LIKE ? OR bundle LIKE ?)"
            args += ["%\(app)%", "%\(app)%"]
        }
        sql += " ORDER BY start_ms LIMIT 2000"
        var rows = store.query(sql, args)
        var apps: [String: Int64] = [:]
        for i in rows.indices {
            let start = max(rows[i]["start_ms"] as? Int64 ?? 0, from)
            let end = min(rows[i]["end_ms"] as? Int64 ?? 0, to)
            // A span seen once still counts for one sampling interval.
            let ms = max(end - start, Int64(options.interval * 1000))
            rows[i]["durationMs"] = ms
            apps[rows[i]["app"] as? String ?? "", default: 0] += ms
            if req["text"] as? Bool == true, let id = rows[i]["id"] as? Int64,
               let entry = store.query("SELECT id, text FROM entries WHERE span_id = ? ORDER BY ts_ms DESC LIMIT 1", [id]).first {
                rows[i]["entry"] = entry["id"]
                rows[i]["excerpt"] = String((entry["text"] as? String ?? "").replacingOccurrences(of: "\n", with: " ⏎ ").prefix(240))
            }
        }
        let rollup = apps.map { ["app": $0.key, "durationMs": $0.value] as [String: Any] }
            .sorted { ($0["durationMs"] as! Int64) > ($1["durationMs"] as! Int64) }
        return ["ok": true, "result": ["apps": rollup, "spans": rows]]
    case "search":
        guard let store = store else { return ["ok": false, "error": "no_store"] }
        let query = (req["query"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return ["ok": false, "error": "empty_query"] }
        let limit = min(max(int("limit") ?? 10, 1), 40)
        let from = int("fromMs") ?? 0
        let to = int("toMs") ?? nowMs()
        let terms = query.split(separator: " ").map(String.init)
        var sql: String
        var args: [Any]
        // The trigram index cannot match terms shorter than three characters; scan for those.
        if terms.allSatisfy({ $0.count >= 3 }) {
            sql = "SELECT e.id, e.ts_ms, e.text, s.app, s.title, s.url FROM entries_fts f JOIN entries e ON e.id = f.rowid JOIN spans s ON s.id = e.span_id WHERE entries_fts MATCH ? AND e.ts_ms BETWEEN ? AND ?"
            args = [ftsQuery(query), from, to]
        } else {
            sql = "SELECT e.id, e.ts_ms, e.text, s.app, s.title, s.url FROM entries e JOIN spans s ON s.id = e.span_id WHERE " + terms.map { _ in "e.text LIKE ?" }.joined(separator: " AND ") + " AND e.ts_ms BETWEEN ? AND ?"
            args = terms.map { "%\($0)%" } + [from, to]
        }
        if let app = req["app"] as? String, !app.isEmpty {
            sql += " AND (s.app LIKE ? OR s.bundle LIKE ?)"
            args += ["%\(app)%", "%\(app)%"]
        }
        // Many entries of one window repeat the same text; fetch extra and keep one hit per window title.
        sql += " ORDER BY e.ts_ms DESC LIMIT ?"
        args.append(limit * 8)
        var hits: [[String: Any]] = []
        var seenWindows = Set<String>()
        for row in store.query(sql, args) {
            let window = "\(row["app"] as? String ?? "")\u{1}\(row["title"] as? String ?? "")"
            if seenWindows.contains(window) { continue }
            seenWindows.insert(window)
            hits.append([
                "entry": row["id"] ?? 0, "tsMs": row["ts_ms"] ?? 0, "app": row["app"] ?? "", "title": row["title"] ?? "",
                "url": row["url"] ?? "", "excerpt": excerpt(row["text"] as? String ?? "", around: query),
            ])
            if hits.count >= Int(limit) { break }
        }
        return ["ok": true, "result": ["hits": hits]]
    case "get":
        guard let store = store else { return ["ok": false, "error": "no_store"] }
        guard let id = int("entry"), let row = store.query(
            "SELECT e.id, e.ts_ms, e.text, s.app, s.title, s.url FROM entries e JOIN spans s ON s.id = e.span_id WHERE e.id = ?", [id]).first
        else { return ["ok": false, "error": "not_found"] }
        return ["ok": true, "result": [
            "entry": row["id"] ?? 0, "tsMs": row["ts_ms"] ?? 0, "app": row["app"] ?? "", "title": row["title"] ?? "",
            "url": row["url"] ?? "", "text": row["text"] ?? "",
        ]]
    default:
        return ["ok": false, "error": "unknown_op"]
    }
}

// MARK: - Main

let argv = CommandLine.arguments
guard argv.count >= 2 else {
    FileHandle.standardError.write("usage: dsh-screen-helper permcheck | serve --db <path> [...]\n".data(using: .utf8)!)
    exit(2)
}

if argv[1] == "permcheck" {
    emit(["accessibility": AXIsProcessTrusted(), "screenRecording": CGPreflightScreenCaptureAccess()])
    exit(0)
}

guard argv[1] == "serve" else { exit(2) }
var i = 2
while i < argv.count {
    let flag = argv[i]
    let value: String? = i + 1 < argv.count ? argv[i + 1] : nil
    switch flag {
    case "--memory": options.memory = true; i += 1; continue
    case "--db": options.db = value ?? ""
    case "--interval": options.interval = max(Double(value ?? "") ?? 5, 2)
    case "--retention-days": options.retentionDays = max(Int(value ?? "") ?? 30, 1)
    case "--ignore-bundle": if let v = value { options.ignoreBundles.insert(v) }
    case "--ignore-url": if let v = value { options.ignoreURLs.append(v) }
    case "--exclude-bundle": if let v = value { options.excludeBundles.insert(v) }
    default: break
    }
    i += 2
}

let store: Store? = options.db.isEmpty ? nil : Store(path: options.db)
var collector: Collector?
if options.memory, let store = store {
    store.prune(retentionDays: options.retentionDays)
    collector = Collector(store: store)
}

// Requests are read off the main thread and answered on it: AX calls and the sampling timer share one run loop.
Thread.detachNewThread {
    while let line = readLine(strippingNewline: true) {
        guard let data = line.data(using: .utf8),
              let req = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
        DispatchQueue.main.async {
            var reply = handle(req, store: store, collector: collector)
            if let id = req["id"] { reply["id"] = id }
            emit(reply)
        }
    }
    exit(0)
}

DispatchQueue.main.async {
    emit(["ready": true, "accessibility": AXIsProcessTrusted(), "memory": collector != nil])
    collector?.start(interval: options.interval)
}
RunLoop.main.run()

import Foundation
import Network

/// RockSniffer's addon service (RockSniffer/Addons/AddonServiceListener.cs) on 127.0.0.1 only:
///   GET /                       the overlay state (Overlay.response), as text/json
///   GET|PUT /storage/<addon>/<key>   a value an addon keeps (files in storageDir; "null" if none)
///   GET /addons/...             the bundled addons; a folder gives the index page, and
///                               addons/config.js is generated with this port
///   OPTIONS                     empty
/// Every response allows any origin and method, and the connection closes after it. Requests whose
/// Host isn't 127.0.0.1 or localhost with this port get 403 (DNS rebinding), and so do PUTs from
/// a web page other than the addons' own.
final class OverlayServer {
    let port: Int
    private let addonsDir: String?
    private let storageDir: String
    private let state: @MainActor () -> Data
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "rs-companion.overlay")

    init(port: Int, addonsDir: String?, storageDir: String, state: @escaping @MainActor () -> Data) {
        self.port = port
        self.addonsDir = addonsDir
        self.storageDir = storageDir
        self.state = state
    }

    /// Returns an error message, or nil when listening.
    func start() -> String? {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return "bad port" }
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
        let listener: NWListener
        do { listener = try NWListener(using: params) } catch { return "\(error)" }
        // Binding fails asynchronously; wait briefly for the outcome.
        let ready = DispatchSemaphore(value: 0)
        var failure: String?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case let .failed(error): failure = "\(error)"; ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] c in self?.serve(c) }
        listener.start(queue: queue)
        if ready.wait(timeout: .now() + 2) == .timedOut { failure = "timed out" }
        if let failure {
            listener.cancel()
            return failure
        }
        listener.stateUpdateHandler = nil
        self.listener = listener
        return nil
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: Requests

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, Data())
        queue.asyncAfter(deadline: .now() + 5) { c.cancel() }  // stalled clients
    }

    private func receive(_ c: NWConnection, _ got: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, error in
            guard let self else { return c.cancel() }
            var buf = got
            if let data { buf += data }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
                let length = Self.header("content-length", in: head).map { Int($0) ?? -1 } ?? 0
                guard length >= 0 else { return self.respond(c, 400, "Bad Request", "text/html") }
                let body = buf[end.upperBound...]
                if body.count >= length || done || error != nil {
                    return self.handle(c, head: head, body: Data(body.prefix(length)))
                }
            }
            if done || error != nil || buf.count > 1 << 20 { return c.cancel() }
            self.receive(c, buf)
        }
    }

    private func handle(_ c: NWConnection, head: String, body: Data) {
        let request = head.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = request.split(separator: " ")
        guard parts.count >= 2 else { return respond(c, 400, "Bad Request", "text/html") }
        let method = String(parts[0])
        var path = String(parts[1])
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        path = path.removingPercentEncoding ?? path

        // A website that points its own name at 127.0.0.1 (DNS rebinding) sends that name as Host.
        if let host = Self.header("host", in: head), !localNames.contains(host.lowercased()) {
            return respond(c, 403, "Forbidden", "text/html")
        }
        if method == "OPTIONS" { return respond(c, 200, "", "text/html") }
        if path.hasPrefix("/storage/") {
            let p = path.dropFirst(9).split(separator: "/").map(String.init)
            guard p.count == 2, p.allSatisfy(Self.safeName) else { return respond(c, 400, "Bad Request", "text/html") }
            let file = storageDir + "/" + p[0] + "/" + p[1] + ".json"
            if method == "PUT" {
                // Writes only from the addon pages (served here, or opened as files: "null") and from
                // programs (no Origin); browsers send any other website's origin.
                if let origin = Self.header("origin", in: head), origin != "null",
                   !localNames.contains(where: { origin.lowercased() == "http://" + $0 }) {
                    return respond(c, 403, "Forbidden", "text/html")
                }
                try? FileManager.default.createDirectory(atPath: storageDir + "/" + p[0], withIntermediateDirectories: true)
                let value = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                try? value.write(toFile: file, atomically: true, encoding: .utf8)
                return respond(c, 200, "", "text/html")
            }
            let value = (try? String(contentsOfFile: file, encoding: .utf8)) ?? "null"
            return respond(c, 200, value, "text/json")
        }
        if method == "GET" && (path == "/addons" || path.hasPrefix("/addons/")) { return addon(c, String(path.dropFirst(7))) }
        if method != "GET" { return respond(c, 405, "Method Not Allowed", "text/html") }
        DispatchQueue.main.async {
            let data = MainActor.assumeIsolated { self.state() }
            self.queue.async { self.send(c, 200, "OK", data, "text/json") }
        }
    }

    /// The names this server is reached by, with the port, as in Host headers.
    private var localNames: [String] { ["127.0.0.1:\(port)", "localhost:\(port)"] }

    /// The value of a request header (name lowercased), or nil.
    private static func header(_ name: String, in head: String) -> String? {
        head.split(separator: "\r\n").dropFirst().lazy.compactMap { line -> String? in
            let p = line.split(separator: ":", maxSplits: 1)
            return p.count == 2 && p[0].lowercased() == name ? p[1].trimmingCharacters(in: .whitespaces) : nil
        }.first
    }

    private static func safeName(_ s: String) -> Bool {
        !s.isEmpty && s != "." && s != ".." && s.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
    }

    private static let types = [
        "html": "text/html", "htm": "text/html", "css": "text/css", "js": "text/javascript", "json": "application/json",
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "svg": "image/svg+xml",
        "ico": "image/x-icon", "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "txt": "text/plain",
    ]

    /// A file of the bundled addons (rel: the path after /addons, e.g. "/timeline/timeline.html").
    private func addon(_ c: NWConnection, _ rel: String) {
        guard let root = addonsDir else { return respond(c, 500, "Addons folder not found", "text/html") }
        let parts = rel.split(separator: "/").map(String.init)
        guard !parts.contains(where: { $0 == ".." || $0 == "." }) else { return respond(c, 404, "File Not Found", "text/html") }
        if parts == ["config.js"] {
            let js = "// THIS FILE IS AUTOMATICALLY GENERATED\n\n// Sniffer addon service connection details\n"
                + "var ip = \"127.0.0.1\";\nvar port = \(port);\nvar defaultPath = \"Lead\";\n"
            return respond(c, 200, js, "text/javascript")
        }
        let ext = (rel as NSString).pathExtension.lowercased()
        if ext.isEmpty {
            let dirs = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted()
                .filter { $0 != "_deps" && !$0.hasPrefix(".") }
                .filter { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: root + "/" + $0, isDirectory: &d) && d.boolValue }
            let items = dirs.map { "<li><a href='/addons/\($0)/\(Self.entry(root, $0))'>\($0)</a></li>" }.joined()
            let page = "<html><head><title>Rocksniffer Addon Index</title></head><body><h1>Available Addons:</h1><ul>\(items)</ul></body></html>"
            return respond(c, 200, page, "text/html")
        }
        let file = ([root] + parts).joined(separator: "/")
        guard let data = FileManager.default.contents(atPath: file) else { return respond(c, 404, "File Not Found", "text/html") }
        send(c, 200, "OK", data, Self.types[ext] ?? "application/octet-stream")
    }

    /// The addon's page: "<name>.html" as RockSniffer links it, else the folder's only .html.
    static func entry(_ root: String, _ name: String) -> String {
        if FileManager.default.fileExists(atPath: "\(root)/\(name)/\(name).html") { return "\(name).html" }
        let html = ((try? FileManager.default.contentsOfDirectory(atPath: "\(root)/\(name)")) ?? []).filter { $0.hasSuffix(".html") }.sorted()
        return html.first ?? "\(name).html"
    }

    private func respond(_ c: NWConnection, _ code: Int, _ text: String, _ type: String) {
        send(c, code, code == 200 ? "OK" : text, Data(text.utf8), type)
    }

    private func send(_ c: NWConnection, _ code: Int, _ reason: String, _ body: Data, _ type: String) {
        let head = "HTTP/1.1 \(code) \(reason)\r\nContent-Length: \(body.count)\r\nContent-Type: \(type)\r\n"
            + "Access-Control-Allow-Methods: *\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }
}

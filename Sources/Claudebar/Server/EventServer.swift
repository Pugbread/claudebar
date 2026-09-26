import Foundation
import Network

/// Tiny loopback-only HTTP endpoint that `hooks/claudebar-hook.sh` posts Claude Code hook payloads to.
///
///   POST /event   hook payload (JSON body, metadata in X-Claudebar-* headers)
///   GET  /state   JSON snapshot of what Claudebar currently knows, for debugging
///   POST /demo    play the built-in demo sequence
///   POST /peek    pop the expanded panel open for a few seconds
///   GET  /events  the last 300 raw hook payloads, oldest first, for debugging
///   GET  /health  liveness probe
final class EventServer: @unchecked Sendable {
    static var configuredPort: UInt16 {
        ProcessInfo.processInfo.environment["CLAUDEBAR_PORT"].flatMap(UInt16.init) ?? 47823
    }

    let port: UInt16
    var onEvent: (@MainActor (HookEnvelope) -> Void)?
    var onStateRequest: (@MainActor () -> Data)?
    var onDemoRequest: (@MainActor () -> Void)?
    var onPeekRequest: (@MainActor () -> Void)?

    private let queue = DispatchQueue(label: "claudebar.event-server")
    /// Raw payloads as received (touched only on `queue`).
    private var recentBodies: [Data] = []
    private var listener: NWListener?
    private static let maxRequestBytes = 64 << 20

    init(port: UInt16) {
        self.port = port
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? 47823)
        listener.stateUpdateHandler = { [port] state in
            if case .failed(let error) = state {
                NSLog("Claudebar: listener on port \(port) failed: \(error)")
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = HTTPRequest(parsing: buffer) {
                route(request, on: connection)
            } else if isComplete || error != nil || buffer.count > Self.maxRequestBytes {
                connection.cancel()
            } else {
                receive(on: connection, buffer: buffer)
            }
        }
    }

    private func route(_ request: HTTPRequest, on connection: NWConnection) {
        switch (request.method, request.path) {
        case ("POST", "/event"):
            // Resolve the envelope (including the Claude PID walk) before replying,
            // while the hook's process tree is guaranteed to still be alive.
            let envelope = HookEnvelope(body: request.body, headers: request.headers)
            send(on: connection, status: "204 No Content")
            recentBodies.append(Self.tagged(request.body, agent: envelope?.agent))
            if recentBodies.count > 300 { recentBodies.removeFirst(recentBodies.count - 300) }
            if let envelope {
                onMain { $0.onEvent?(envelope) }
            }
        case ("GET", "/state"):
            onMain { server in
                let body = server.onStateRequest?() ?? Data()
                server.queue.async {
                    server.send(on: connection, status: "200 OK", body: body, contentType: "application/json")
                }
            }
        case ("GET", "/demo"), ("POST", "/demo"):
            send(on: connection, status: "202 Accepted")
            onMain { $0.onDemoRequest?() }
        case ("GET", "/peek"), ("POST", "/peek"):
            send(on: connection, status: "202 Accepted")
            onMain { $0.onPeekRequest?() }
        case ("GET", "/events"):
            var body = Data("[".utf8)
            for (index, event) in recentBodies.enumerated() {
                if index > 0 { body.append(Data(",".utf8)) }
                body.append(event)
            }
            body.append(Data("]".utf8))
            send(on: connection, status: "200 OK", body: body, contentType: "application/json")
        case ("GET", "/health"):
            send(on: connection, status: "200 OK", body: Data("ok\n".utf8), contentType: "text/plain")
        default:
            send(on: connection, status: "404 Not Found")
        }
    }

    /// The payload with `received_at` and `agent` added, so /events reads as a timeline.
    private static func tagged(_ body: Data, agent: Agent?) -> Data {
        guard var object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return body }
        object["received_at"] = ISO8601DateFormatter().string(from: Date())
        object["agent"] = agent?.rawValue
        return (try? JSONSerialization.data(withJSONObject: object)) ?? body
    }

    private func onMain(_ work: @escaping @MainActor (EventServer) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { work(self) }
        }
    }

    private func send(on connection: NWConnection, status: String, body: Data = Data(), contentType: String = "text/plain") {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var response = Data(head.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// Just enough HTTP/1.1 to read one request with a Content-Length body.
struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    init?(parsing data: Data) {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headData = data.subdata(in: data.startIndex..<headerEnd.lowerBound)
        guard let head = String(data: headData, encoding: .utf8) ?? String(data: headData, encoding: .isoLatin1) else { return nil }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let length = Int(headers["content-length"] ?? "") ?? 0
        let bodyStart = headerEnd.upperBound
        guard data.endIndex - bodyStart >= length else { return nil }

        method = String(requestLine[0])
        path = String(requestLine[1].split(separator: "?", maxSplits: 1).first ?? "")
        self.headers = headers
        body = data.subdata(in: bodyStart..<(bodyStart + length))
    }
}

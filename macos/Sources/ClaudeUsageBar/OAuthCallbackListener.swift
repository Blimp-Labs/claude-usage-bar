import Foundation
import Network

/// Receives the browser's sign-in redirect on 127.0.0.1, the way Claude Code
/// does, so signing in doesn't need a pasted code.
final class OAuthCallbackListener: @unchecked Sendable {
    /// Gets the `/callback` query and returns the page the browser shows.
    typealias Handler = @Sendable ([URLQueryItem]) async -> (status: Int, html: String)

    private(set) var port: UInt16 = 0
    var redirectURI: String { "http://localhost:\(port)/callback" }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "OAuthCallbackListener")
    private let handler: Handler

    private init(listener: NWListener, handler: @escaping Handler) {
        self.listener = listener
        self.handler = handler
    }

    static func start(handler: @escaping Handler) async throws -> OAuthCallbackListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let callbackListener = OAuthCallbackListener(listener: try NWListener(using: parameters), handler: handler)
        callbackListener.port = try await callbackListener.startListening()
        return callbackListener
    }

    func stop() {
        listener.cancel()
    }

    private func startListening() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            // Cleared on first use so the continuation can't resume twice.
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error), .waiting(let error):
                    listener.stateUpdateHandler = nil
                    listener.cancel()
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.start(queue: queue)
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffered: Data())
    }

    private func receive(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            let buffered = buffered + (data ?? Data())
            if let headerEnd = buffered.range(of: Data("\r\n\r\n".utf8)), let self {
                self.respond(to: buffered[..<headerEnd.lowerBound], on: connection)
            } else if isComplete || error != nil || buffered.count > 16_384 || self == nil {
                connection.cancel()
            } else {
                self?.receive(on: connection, buffered: buffered)
            }
        }
    }

    private func respond(to requestHead: Data, on connection: NWConnection) {
        // Request line: "GET /callback?code=…&state=… HTTP/1.1"
        let requestLine = String(decoding: requestHead, as: UTF8.self).components(separatedBy: "\r\n")[0]
        let parts = requestLine.split(separator: " ")
        guard parts.count == 3, parts[0] == "GET",
              let components = URLComponents(string: "http://localhost\(parts[1])"),
              components.path == "/callback" else {
            send(status: 404, html: "Not found", on: connection)
            return
        }

        let query = components.queryItems ?? []
        Task {
            let response = await handler(query)
            send(status: response.status, html: response.html, on: connection)
        }
    }

    private func send(status: Int, html: String, on connection: NWConnection) {
        let reason = [200: "OK", 400: "Bad Request", 404: "Not Found"][status] ?? "Error"
        let body = Data(html.utf8)
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}

#if os(macOS)
import Foundation
import Network

/// A small HTTP/1.1 server on Network.framework: what the remote MCP endpoint needs behind a tunnel (cloudflared
/// speaks HTTP/1.1 to its origin). Keep-alive, `Content-Length` and chunked request bodies, and streamed responses
/// (Server-Sent Events) sent chunked. No TLS: the tunnel ends HTTPS.
public final class HTTPListener: @unchecked Sendable {
    public struct Request: Sendable {
        public var method: String
        /// The path without its query, percent-decoded.
        public var path: String
        public var query: [String: String]
        /// Header names in lower case; a repeated header keeps its last value.
        public var headers: [String: String]
        public var body: Data
        public var remote: String

        public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data(), remote: String = "") {
            self.method = method
            self.path = path
            self.query = query
            self.headers = headers
            self.body = body
            self.remote = remote
        }
    }

    public enum Response: Sendable {
        case full(status: Int, headers: [String: String], body: Data)
        case stream(status: Int, headers: [String: String], body: AsyncThrowingStream<Data, Error>)

        public var status: Int {
            switch self {
            case .full(let status, _, _), .stream(let status, _, _): status
            }
        }
    }

    public typealias Handler = @Sendable (Request) async -> Response

    static let maximumHead = 32 * 1024
    static let maximumBody = 8 * 1024 * 1024

    private let listener: NWListener
    private let handler: Handler
    private let queue = DispatchQueue(label: "apple-mail-mcp.http")

    /// Listens on `host` (an address, or nil for every interface) and `port` (0 picks one).
    public init(host: String?, port: UInt16, handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if let host, !host.isEmpty {
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any)
            listener = try NWListener(using: parameters)
        } else {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? .any)
        }
        self.handler = handler
    }

    /// The port it listens on, once started.
    public var port: UInt16? { listener.port?.rawValue }

    /// Starts listening; returns once the port is open, throws when it cannot be.
    public func start() async throws {
        listener.newConnectionHandler = { [handler, queue] connection in
            connection.start(queue: queue)
            Task { await Self.serve(connection, handler: handler) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once(continuation)
            let finish: @Sendable (Error?) -> Void = { once.resume($0) }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(nil)
                case .failed(let error): finish(error)
                case .waiting(let error): finish(error)
                case .cancelled: finish(CancellationError())
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() { listener.cancel() }

    /// Resumes a continuation the first time only: the listener reports several states.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?

        init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }

        func resume(_ error: Error?) {
            guard let continuation = lock.withLock({ () -> CheckedContinuation<Void, Error>? in
                defer { self.continuation = nil }
                return self.continuation
            }) else { return }
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
    }

    // MARK: Connections

    private static func serve(_ connection: NWConnection, handler: Handler) async {
        defer { connection.cancel() }
        let remote: String = {
            if case .hostPort(let host, _) = connection.endpoint { return "\(host)" }
            return ""
        }()
        var buffer = Data()
        while true {
            guard let request = try? await readRequest(connection, buffer: &buffer, remote: remote) else { return }
            let response = await handler(request)
            let close = request.headers["connection"]?.lowercased() == "close"
            do {
                try await write(response, to: connection, close: close)
            } catch {
                return
            }
            if close { return }
        }
    }

    private static func receive(_ connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: isComplete ? nil : Data())
                }
            }
        }
    }

    private static func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    struct Malformed: Error {}

    /// Reads more into `buffer` until it holds `count` bytes; false when the peer is gone.
    private static func fill(_ connection: NWConnection, _ buffer: inout Data, to count: Int) async throws -> Bool {
        while buffer.count < count {
            guard let more = try await receive(connection) else { return false }
            buffer.append(more)
        }
        return true
    }

    private static let headEnd = Data("\r\n\r\n".utf8)
    private static let lineEnd = Data("\r\n".utf8)

    /// The next request on the connection; nil when the peer closed it between requests.
    static func readRequest(_ connection: NWConnection, buffer: inout Data, remote: String) async throws -> Request? {
        var end = buffer.range(of: headEnd)
        while end == nil {
            guard buffer.count < maximumHead, let more = try await receive(connection) else { return nil }
            buffer.append(more)
            end = buffer.range(of: headEnd)
        }
        let head = String(decoding: buffer[buffer.startIndex..<end!.lowerBound], as: UTF8.self)
        buffer = Data(buffer[end!.upperBound...])
        var request = try parseHead(head, remote: remote)
        if request.headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            var body = Data()
            while true {
                var lineRange = buffer.range(of: lineEnd)
                while lineRange == nil {
                    guard buffer.count < maximumHead, let more = try await receive(connection) else { throw Malformed() }
                    buffer.append(more)
                    lineRange = buffer.range(of: lineEnd)
                }
                let sizeText = String(decoding: buffer[buffer.startIndex..<lineRange!.lowerBound], as: UTF8.self)
                guard let size = Int(sizeText.split(separator: ";").first?.trimmingCharacters(in: .whitespaces) ?? "", radix: 16), size >= 0 else {
                    throw Malformed()
                }
                buffer = Data(buffer[lineRange!.upperBound...])
                guard body.count + size <= maximumBody, try await fill(connection, &buffer, to: size + 2) else { throw Malformed() }
                if size == 0 {
                    // Trailers are not used: skip to the blank line.
                    while buffer.range(of: lineEnd)?.lowerBound != buffer.startIndex {
                        guard let trailerEnd = buffer.range(of: lineEnd) else {
                            guard let more = try await receive(connection) else { throw Malformed() }
                            buffer.append(more)
                            continue
                        }
                        buffer = Data(buffer[trailerEnd.upperBound...])
                    }
                    buffer = Data(buffer.dropFirst(2))
                    break
                }
                body.append(buffer.prefix(size))
                buffer = Data(buffer.dropFirst(size + 2))
            }
            request.body = body
        } else if let length = request.headers["content-length"].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), length > 0 {
            guard length <= maximumBody, try await fill(connection, &buffer, to: length) else { throw Malformed() }
            request.body = Data(buffer.prefix(length))
            buffer = Data(buffer.dropFirst(length))
        }
        return request
    }

    static func parseHead(_ head: String, remote: String) throws -> Request {
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { throw Malformed() }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let target = String(requestLine[1])
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let path = components?.path ?? target.split(separator: "?").first.map(String.init) ?? target
        return Request(method: String(requestLine[0]).uppercased(), path: path.isEmpty ? "/" : path, query: query, headers: headers, remote: remote)
    }

    // MARK: Responses

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 204: "No Content"
        case 302: "Found"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 406: "Not Acceptable"
        case 409: "Conflict"
        case 415: "Unsupported Media Type"
        case 421: "Misdirected Request"
        case 429: "Too Many Requests"
        case 503: "Service Unavailable"
        default: status < 500 ? "Error" : "Server Error"
        }
    }

    static func head(status: Int, headers: [String: String], extra: [String: String]) -> Data {
        var text = "HTTP/1.1 \(status) \(reason(status))\r\n"
        for (name, value) in headers.merging(extra, uniquingKeysWith: { _, new in new }).sorted(by: { $0.key < $1.key }) {
            // Header values come from this code, but never let one split the head.
            guard !name.contains(where: \.isNewline), !value.contains(where: \.isNewline) else { continue }
            text += "\(name): \(value)\r\n"
        }
        return Data((text + "\r\n").utf8)
    }

    private static func write(_ response: Response, to connection: NWConnection, close: Bool) async throws {
        switch response {
        case .full(let status, let headers, let body):
            var extra = ["Content-Length": String(body.count)]
            if close { extra["Connection"] = "close" }
            try await send(head(status: status, headers: headers, extra: extra) + body, on: connection)
        case .stream(let status, let headers, let body):
            try await send(head(status: status, headers: headers, extra: ["Transfer-Encoding": "chunked", "Cache-Control": "no-cache"]), on: connection)
            do {
                for try await chunk in body where !chunk.isEmpty {
                    try await send(Data(String(chunk.count, radix: 16).utf8) + lineEnd + chunk + lineEnd, on: connection)
                }
            } catch {
                // The stream ended with an error: end the response cleanly all the same.
            }
            try await send(Data("0\r\n\r\n".utf8), on: connection)
        }
    }
}
#endif

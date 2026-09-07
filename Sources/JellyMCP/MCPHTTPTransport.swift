import Foundation

/// Loopback-only HTTP/1.1 endpoint that adapts MCP JSON-RPC over `POST /mcp`.
///
/// Deliberately a small POSIX implementation bound to 127.0.0.1: a kernel-level
/// loopback listener never triggers the local-network privacy prompt or the
/// application firewall, and it needs no third-party HTTP dependency. Every
/// response uses `Connection: close`; MCP traffic is small and sequential.
public final class MCPHTTPServer: @unchecked Sendable {
    private let core: MCPServerCore
    private let token: String
    private let stateLock = NSLock()
    private var serverFD: Int32 = -1
    private var isStopped = false
    private var boundPort: UInt16?

    /// Highest accepted body size: initialize/tools traffic is tiny; a
    /// tools/call carrying long notes stays far below this.
    private static let maxBodyBytes = 2_000_000
    private static let maxHeaderBytes = 32_000
    private static let ioTimeoutSeconds = 15

    public init(core: MCPServerCore, token: String) {
        self.core = core
        self.token = token
    }

    /// Actual bound port (port 0 requests get an ephemeral port).
    public var port: UInt16? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return boundPort
    }

    /// Binds 127.0.0.1, scanning forward from `preferredPort` when the address
    /// is taken. Returns the bound port.
    @discardableResult
    public func start(preferredPort: UInt16 = 8787, portScanLimit: UInt16 = 16) throws -> UInt16 {
        stateLock.lock()
        let alreadyRunning = serverFD >= 0
        stateLock.unlock()
        guard !alreadyRunning else {
            guard let boundPort else {
                throw MCPHTTPServerError.startFailed("服务器已启动但端口未知。")
            }
            return boundPort
        }

        var lastError: String = "unknown"
        for offset in 0...max(0, Int(portScanLimit)) {
            let candidate = UInt16(Int(preferredPort) + offset)
            do {
                let fd = try bindListener(port: candidate)
                stateLock.lock()
                serverFD = fd
                isStopped = false
                stateLock.unlock()
                let actual = try Self.port(of: fd)
                stateLock.lock()
                boundPort = actual
                stateLock.unlock()
                Thread(block: { [weak self] in self?.acceptLoop(fd: fd) }).start()
                return actual
            } catch MCPHTTPServerError.addressInUse {
                lastError = "端口 \(candidate) 已被占用"
                continue
            }
        }
        throw MCPHTTPServerError.startFailed("无法绑定 127.0.0.1（\(lastError)，尝试了 \(preferredPort) 起共 \(portScanLimit + 1) 个端口）。")
    }

    public func stop() {
        stateLock.lock()
        isStopped = true
        let fd = serverFD
        serverFD = -1
        boundPort = nil
        stateLock.unlock()
        guard fd >= 0 else { return }
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }

    // MARK: Listener plumbing

    private func bindListener(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw MCPHTTPServerError.startFailed("socket() 失败：errno \(errno)")
        }
        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            close(fd)
            if code == EADDRINUSE {
                throw MCPHTTPServerError.addressInUse
            }
            throw MCPHTTPServerError.startFailed("bind(127.0.0.1:\(port)) 失败：errno \(code)")
        }
        guard listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            throw MCPHTTPServerError.startFailed("listen() 失败：errno \(code)")
        }
        return fd
    }

    private static func port(of fd: Int32) throws -> UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard result == 0 else {
            throw MCPHTTPServerError.startFailed("getsockname() 失败：errno \(errno)")
        }
        return UInt16(bigEndian: address.sin_port)
    }

    private func acceptLoop(fd: Int32) {
        while true {
            stateLock.lock()
            let stopped = isStopped
            stateLock.unlock()
            if stopped { break }

            var address = sockaddr()
            var length = socklen_t(MemoryLayout<sockaddr>.size)
            let clientFD = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(fd, $0, &length)
                }
            }
            guard clientFD >= 0 else {
                stateLock.lock()
                let stoppedNow = isStopped
                stateLock.unlock()
                if stoppedNow { break }
                if errno == EBADF || errno == EINVAL { break }
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.serve(clientFD: clientFD)
            }
        }
    }

    // MARK: Per-connection handling

    private func serve(clientFD: Int32) {
        defer { close(clientFD) }
        configure(clientFD: clientFD)

        guard let request = readRequest(clientFD: clientFD) else {
            return
        }

        switch request {
        case .badPath:
            respond(
                clientFD: clientFD,
                status: "404 Not Found",
                body: Data("{\"error\":\"unknown path\"}".utf8),
                contentType: "application/json",
                extraHeaders: []
            )
        case .badMethod:
            respond(
                clientFD: clientFD,
                status: "405 Method Not Allowed",
                body: Data("{\"error\":\"POST /mcp only\"}".utf8),
                contentType: "application/json",
                extraHeaders: ["Allow: POST"]
            )
        case .unauthorized:
            respond(
                clientFD: clientFD,
                status: "401 Unauthorized",
                body: Data("{\"error\":\"unauthorized\"}".utf8),
                contentType: "application/json",
                extraHeaders: []
            )
        case let .call(body):
            respondToCall(clientFD: clientFD, body: body)
        }
    }

    private func respondToCall(clientFD: Int32, body: Data) {
        let semaphore = DispatchSemaphore(value: 0)
        final class ResponseBox: @unchecked Sendable {
            var data: Data?
        }
        let box = ResponseBox()
        let core = self.core
        let task = Task.detached(priority: .userInitiated) {
            box.data = await core.handle(body)
            semaphore.signal()
        }
        semaphore.wait()
        task.cancel()

        if let response = box.data {
            respond(
                clientFD: clientFD,
                status: "200 OK",
                body: response,
                contentType: "application/json",
                extraHeaders: []
            )
        } else {
            // Notifications get no JSON-RPC response; 202 signals acceptance.
            respond(clientFD: clientFD, status: "202 Accepted", body: Data(), contentType: nil, extraHeaders: [])
        }
    }

    private func configure(clientFD: Int32) {
        var nosigpipe: Int32 = 1
        _ = setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: Self.ioTimeoutSeconds, tv_usec: 0)
        _ = setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    // MARK: Request parsing

    private enum ParsedRequest {
        case call(body: Data)
        case badPath
        case badMethod
        case unauthorized
    }

    private func readRequest(clientFD: Int32) -> ParsedRequest? {
        var buffer = Data()
        let chunkSize = 8192
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        let headerTerminator = Data("\r\n\r\n".utf8)

        var headerEnd = buffer.range(of: headerTerminator)
        while headerEnd == nil {
            if buffer.count > Self.maxHeaderBytes { return nil }
            let received = recv(clientFD, &chunk, chunkSize, 0)
            guard received > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<received])
            headerEnd = buffer.range(of: headerTerminator)
        }

        let headRange = 0..<headerEnd!.lowerBound
        let head = String(data: buffer.subdata(in: headRange), encoding: .utf8) ?? ""
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst()
        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 3 else { return nil }
        let method = String(requestParts[0])
        let rawPath = String(requestParts[1])
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath

        var contentLength = 0
        var authorized = false
        for line in lines {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            switch name {
            case "content-length":
                contentLength = Int(value) ?? 0
            case "authorization":
                if value.lowercased().hasPrefix("bearer "),
                   value.dropFirst("bearer ".count).trimmingCharacters(in: .whitespaces) == token {
                    authorized = true
                }
            case "x-jelly-token":
                if value == token {
                    authorized = true
                }
            default:
                break
            }
        }

        guard path == "/mcp" else { return .badPath }
        guard method == "POST" else { return .badMethod }
        guard authorized else { return .unauthorized }
        guard contentLength >= 0, contentLength <= Self.maxBodyBytes else { return nil }

        var body = buffer.subdata(in: headerEnd!.upperBound..<buffer.count)
        while body.count < contentLength {
            let received = recv(clientFD, &chunk, min(chunkSize, contentLength - body.count), 0)
            guard received > 0 else { return nil }
            body.append(contentsOf: chunk[0..<received])
        }
        return .call(body: body)
    }

    private func respond(
        clientFD: Int32,
        status: String,
        body: Data,
        contentType: String?,
        extraHeaders: [String]
    ) {
        var head = "HTTP/1.1 \(status)\r\n"
        if let contentType {
            head += "Content-Type: \(contentType)\r\n"
        }
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        for header in extraHeaders {
            head += "\(header)\r\n"
        }
        head += "\r\n"

        var payload = Data(head.utf8)
        payload.append(body)
        payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let sent = send(clientFD, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                if sent <= 0 { return }
                offset += sent
            }
        }
    }
}

public enum MCPHTTPServerError: Error, Equatable {
    case addressInUse
    case startFailed(String)
}

import Darwin
import CFNetwork
import Foundation
import UniformTypeIdentifiers
import WorkspaceDomain

struct MaterialHTTPLimits: Equatable, Sendable {
    var requestTimeout: TimeInterval = 20
    var resourceTimeout: TimeInterval = 120
    var maxRedirects = 5
    var maxHTMLBytes = 2_000_000
    var maxSubtitleBytes = 10_000_000
    var maxAudioBytes: Int64 = 1_500_000_000
}

enum MaterialHTTPClientError: Error, Equatable {
    case restricted
    case unavailable
    case tooLarge
    case unsupported
}

final class MaterialHTTPClient: @unchecked Sendable {
    typealias URLValidator = @Sendable (URL) -> Bool
    typealias WriteObserver = @Sendable (Int) -> Void

    private let session: URLSession
    private let sessionConfiguration: URLSessionConfiguration
    private let limits: MaterialHTTPLimits
    private let redirectState = RedirectState()
    private let urlValidator: URLValidator

    init(
        limits: MaterialHTTPLimits = .init(),
        configuration: URLSessionConfiguration? = nil,
        urlValidator: @escaping URLValidator = MaterialURLSafety.isPublicHTTPS
    ) {
        self.limits = limits
        self.urlValidator = urlValidator
        let config = ((configuration ?? .ephemeral).copy() as? URLSessionConfiguration) ?? .ephemeral
        config.timeoutIntervalForRequest = limits.requestTimeout
        config.timeoutIntervalForResource = limits.resourceTimeout
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.httpMaximumConnectionsPerHost = 4
        self.sessionConfiguration = config
        let delegate = RedirectDelegate(
            state: redirectState,
            maxRedirects: limits.maxRedirects,
            urlValidator: urlValidator
        )
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    func get(
        _ url: URL,
        headers: [String: String],
        maxBytes: Int
    ) async throws -> (data: Data, response: HTTPURLResponse, finalURL: URL) {
        guard urlValidator(url) else { throw MaterialHTTPClientError.unavailable }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw MaterialHTTPClientError.unavailable }
        if http.statusCode == 401 || http.statusCode == 403 { throw MaterialHTTPClientError.restricted }
        guard (200..<400).contains(http.statusCode) else { throw MaterialHTTPClientError.unavailable }
        guard let finalURL = http.url ?? request.url, urlValidator(finalURL) else {
            throw MaterialHTTPClientError.unavailable
        }
        if http.expectedContentLength > Int64(maxBytes) { throw MaterialHTTPClientError.tooLarge }
        var data = Data()
        data.reserveCapacity(min(maxBytes, max(0, Int(http.expectedContentLength))))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maxBytes else { throw MaterialHTTPClientError.tooLarge }
            data.append(byte)
        }
        return (data, http, finalURL)
    }

    func streamDownload(
        _ url: URL,
        headers: [String: String],
        to destination: URL,
        maxBytes: Int64,
        progress: @escaping @Sendable (Double) -> Void,
        onWrite: WriteObserver? = nil
    ) async throws -> String? {
        guard urlValidator(url) else { throw MaterialHTTPClientError.unavailable }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let delegate = StreamDownloadDelegate(
            destination: destination,
            maxBytes: maxBytes,
            maxRedirects: limits.maxRedirects,
            urlValidator: urlValidator,
            progress: progress,
            onWrite: onWrite
        )
        let session = URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await delegate.start(task)
        } onCancel: {
            task.cancel()
        }
    }
}

private final class StreamDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: URL
    private let maxBytes: Int64
    private let maxRedirects: Int
    private let urlValidator: MaterialHTTPClient.URLValidator
    private let progress: @Sendable (Double) -> Void
    private let onWrite: MaterialHTTPClient.WriteObserver?
    private let redirectState = RedirectState()
    private let lock = NSLock()
    private var handle: FileHandle?
    private var writtenBytes: Int64 = 0
    private var expectedLength: Int64 = NSURLSessionTransferSizeUnknown
    private var mimeType: String?
    private var lastReportedPercent = -1
    private var continuation: CheckedContinuation<String?, Error>?
    private var settled = false

    init(
        destination: URL,
        maxBytes: Int64,
        maxRedirects: Int,
        urlValidator: @escaping MaterialHTTPClient.URLValidator,
        progress: @escaping @Sendable (Double) -> Void,
        onWrite: MaterialHTTPClient.WriteObserver?
    ) {
        self.destination = destination
        self.maxBytes = maxBytes
        self.maxRedirects = maxRedirects
        self.urlValidator = urlValidator
        self.progress = progress
        self.onWrite = onWrite
    }

    func start(_ task: URLSessionDataTask) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let count = redirectState.increment(task)
        guard count <= maxRedirects,
              let url = request.url,
              urlValidator(url)
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            fail(.unavailable)
            return
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            completionHandler(.cancel)
            fail(.restricted)
            return
        }
        guard (200..<300).contains(http.statusCode),
              let finalURL = http.url ?? dataTask.currentRequest?.url,
              urlValidator(finalURL)
        else {
            completionHandler(.cancel)
            fail(.unavailable)
            return
        }
        let expected = http.expectedContentLength
        if expected > maxBytes {
            completionHandler(.cancel)
            fail(.tooLarge)
            return
        }
        do {
            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: destination.path) {
                guard fileManager.createFile(atPath: destination.path, contents: nil) else {
                    throw MaterialHTTPClientError.unavailable
                }
            }
            let handle = try FileHandle(forWritingTo: destination)
            try handle.truncate(atOffset: 0)
            lock.lock()
            self.handle = handle
            expectedLength = expected
            mimeType = http.value(forHTTPHeaderField: "Content-Type")
            lock.unlock()
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            fail(.unavailable)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let handle = self.handle
        let nextCount = writtenBytes + Int64(data.count)
        lock.unlock()
        guard let handle else { return }
        if nextCount > maxBytes {
            dataTask.cancel()
            fail(.tooLarge)
            return
        }
        do {
            try handle.write(contentsOf: data)
            lock.lock()
            writtenBytes = nextCount
            let expected = expectedLength
            let percent: Int?
            if expected > 0 {
                let fraction = min(1, Double(nextCount) / Double(expected))
                percent = Int((fraction * 100).rounded(.down))
            } else {
                percent = nil
            }
            let last = lastReportedPercent
            if let percent, percent != last {
                lastReportedPercent = percent
                lock.unlock()
                progress(min(1, Double(nextCount) / Double(expected)))
            } else {
                lock.unlock()
            }
            onWrite?(data.count)
        } catch {
            dataTask.cancel()
            fail(.unavailable)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        redirectState.remove(task)
        lock.lock()
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        lock.unlock()
        if let error {
            if (error as? URLError)?.code == .cancelled || error is CancellationError {
                fail(CancellationError())
            } else {
                fail(.unavailable)
            }
            return
        }
        progress(1)
        succeed()
    }

    private func succeed() {
        lock.lock()
        guard !settled, let continuation else {
            lock.unlock()
            return
        }
        settled = true
        let mime = mimeType
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: mime)
    }

    private func fail(_ error: Error) {
        lock.lock()
        guard !settled, let continuation else {
            lock.unlock()
            return
        }
        settled = true
        self.continuation = nil
        try? handle?.close()
        handle = nil
        lock.unlock()
        continuation.resume(throwing: error)
    }

    private func fail(_ error: MaterialHTTPClientError) {
        fail(error as Error)
    }
}

private final class RedirectState: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [ObjectIdentifier: Int] = [:]

    func increment(_ task: URLSessionTask) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let key = ObjectIdentifier(task)
        counts[key, default: 0] += 1
        return counts[key] ?? 0
    }

    func remove(_ task: URLSessionTask) {
        lock.lock()
        counts.removeValue(forKey: ObjectIdentifier(task))
        lock.unlock()
    }
}

private final class RedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let state: RedirectState
    let maxRedirects: Int
    let urlValidator: MaterialHTTPClient.URLValidator

    init(
        state: RedirectState,
        maxRedirects: Int,
        urlValidator: @escaping MaterialHTTPClient.URLValidator
    ) {
        self.state = state
        self.maxRedirects = maxRedirects
        self.urlValidator = urlValidator
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let count = state.increment(task)
        guard count <= maxRedirects,
              let url = request.url,
              urlValidator(url)
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        state.remove(task)
    }
}

enum MaterialURLSafety {
    static func isPublicHTTPS(_ url: URL) -> Bool {
        guard let host = validatedHost(for: url) else { return false }
        return isPublicHTTPS(
            url,
            resolvedAddresses: resolvedAddresses(for: host),
            httpsProxyEnabled: systemProxyEnabled()
        )
    }

    static func isPublicHTTPS(
        _ url: URL,
        resolvedAddresses: [String],
        httpsProxyEnabled: Bool
    ) -> Bool {
        guard let host = validatedHost(for: url), !resolvedAddresses.isEmpty else { return false }
        let literalDisposition = addressDisposition(host)
        if literalDisposition != nil {
            return literalDisposition == .publicAddress
        }

        var foundPublicAddress = false
        var foundProxyIPv4 = false
        for rawAddress in resolvedAddresses {
            guard let disposition = addressDisposition(rawAddress) else { return false }
            switch disposition {
            case .publicAddress:
                foundPublicAddress = true
            case .proxySyntheticIPv4:
                foundProxyIPv4 = true
            case .proxySyntheticIPv6:
                continue
            case .privateAddress:
                return false
            }
        }
        return foundPublicAddress || (httpsProxyEnabled && foundProxyIPv4)
    }

    private enum AddressDisposition: Equatable {
        case publicAddress
        case proxySyntheticIPv4
        case proxySyntheticIPv6
        case privateAddress
    }

    private static func validatedHost(for url: URL) -> String? {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              let rawHost = url.host?.lowercased(),
              !rawHost.isEmpty
        else { return nil }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty,
              host != "localhost",
              !host.hasSuffix(".localhost"),
              !host.hasSuffix(".local"),
              !host.hasSuffix(".internal"),
              !host.hasSuffix(".lan"),
              !host.hasSuffix(".home"),
              !host.hasSuffix(".corp")
        else { return nil }
        return host
    }

    private static func resolvedAddresses(for host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(first) }

        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor?.pointee {
            defer { cursor = info.ai_next }
            guard let address = info.ai_addr else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = buffer.withUnsafeMutableBufferPointer { pointer in
                getnameinfo(
                    address,
                    socklen_t(info.ai_addrlen),
                    pointer.baseAddress,
                    socklen_t(pointer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
            }
            if status == 0 {
                let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                addresses.append(String(decoding: bytes, as: UTF8.self))
            }
        }
        return addresses
    }

    private static func systemProxyEnabled() -> Bool {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any]
        else { return false }
        return ["HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable"].contains { key in
            (settings[key] as? NSNumber)?.boolValue == true
        }
    }

    private static func addressDisposition(_ rawAddress: String) -> AddressDisposition? {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, rawAddress, &ipv4) == 1 {
            let value = UInt32(bigEndian: ipv4.s_addr)
            let first = UInt8((value >> 24) & 0xff)
            let second = UInt8((value >> 16) & 0xff)
            if first == 198, second == 18 || second == 19 {
                return .proxySyntheticIPv4
            }
            return isPublicIPv4(value) ? .publicAddress : .privateAddress
        }
        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, rawAddress, &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            if bytes.count == 16, bytes[0] & 0xfe == 0xfc {
                return .proxySyntheticIPv6
            }
            return isPublicIPv6(bytes) ? .publicAddress : .privateAddress
        }
        return nil
    }

    private static func isPublicIPv4(_ address: UInt32) -> Bool {
        let first = UInt8((address >> 24) & 0xff)
        let second = UInt8((address >> 16) & 0xff)
        let third = UInt8((address >> 8) & 0xff)
        if first == 0 || first == 10 || first == 127 || first >= 224 { return false }
        if first == 100, (64...127).contains(second) { return false }
        if first == 169, second == 254 { return false }
        if first == 172, (16...31).contains(second) { return false }
        if first == 192, second == 168 { return false }
        if first == 192, second == 0 { return false }
        if first == 192, second == 0, third == 2 { return false }
        if first == 198, second == 18 || second == 19 { return false }
        if first == 198, second == 51, third == 100 { return false }
        if first == 203, second == 0, third == 113 { return false }
        return true
    }

    private static func isPublicIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes.allSatisfy({ $0 == 0 }) { return false }
        if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes.last == 1 { return false }
        if bytes[0] & 0xfe == 0xfc { return false }
        if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { return false }
        if bytes[0] == 0xff { return false }
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0d, bytes[3] == 0xb8 { return false }
        if bytes[0...9].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            let ipv4 = UInt32(bytes[12]) << 24
                | UInt32(bytes[13]) << 16
                | UInt32(bytes[14]) << 8
                | UInt32(bytes[15])
            return isPublicIPv4(ipv4)
        }
        return true
    }
}

struct RoutedMaterialAcquirer: MaterialAcquiring {
    let bilibili: BilibiliMaterialAcquirer
    let xiaoyuzhou: XiaoyuzhouMaterialAcquirer
    let xiaohongshu: XiaohongshuMaterialAcquirer
    let article: PublicWebArticleAcquirer
    private let recorder: InvocationRecorder?

    init(client: MaterialHTTPClient = MaterialHTTPClient()) {
        self.init(
            bilibili: BilibiliMaterialAcquirer(client: client),
            xiaoyuzhou: XiaoyuzhouMaterialAcquirer(client: client),
            xiaohongshu: XiaohongshuMaterialAcquirer(client: client),
            article: PublicWebArticleAcquirer(client: client)
        )
    }

    init(
        bilibili: BilibiliMaterialAcquirer,
        xiaoyuzhou: XiaoyuzhouMaterialAcquirer,
        xiaohongshu: XiaohongshuMaterialAcquirer? = nil,
        article: PublicWebArticleAcquirer? = nil,
        recorder: InvocationRecorder? = nil
    ) {
        self.bilibili = bilibili
        self.xiaoyuzhou = xiaoyuzhou
        self.xiaohongshu = xiaohongshu ?? XiaohongshuMaterialAcquirer(client: bilibili.client)
        self.article = article ?? PublicWebArticleAcquirer(client: bilibili.client)
        self.recorder = recorder
    }

    init(recordingAdapters: Bool, client: MaterialHTTPClient = MaterialHTTPClient()) {
        self.init(
            bilibili: BilibiliMaterialAcquirer(client: client),
            xiaoyuzhou: XiaoyuzhouMaterialAcquirer(client: client),
            xiaohongshu: XiaohongshuMaterialAcquirer(client: client),
            article: PublicWebArticleAcquirer(client: client),
            recorder: recordingAdapters ? InvocationRecorder() : nil
        )
    }

    var bilibiliInvocationCount: Int {
        recorder?.bilibiliCount ?? 0
    }

    func acquire(_ source: MaterialSource) async throws -> MaterialAcquisition {
        switch source.descriptor.kind {
        case .bilibiliVideo:
            recorder?.bilibiliCount += 1
            return try await bilibili.acquire(source)
        case .xiaoyuzhouEpisode:
            recorder?.xiaoyuzhouCount += 1
            return try await xiaoyuzhou.acquire(source)
        case .publicWebArticle:
            return try await article.acquire(source)
        case .xiaohongshuNote:
            return .composite(try await xiaohongshu.acquire(source))
        case .localText, .localFile:
            throw MaterialDigestPipelineError.unsupportedSource
        }
    }

    final class InvocationRecorder: @unchecked Sendable {
        var bilibiliCount = 0
        var xiaoyuzhouCount = 0
    }
}

struct PublicWebArticleAcquirer: MaterialAcquiring {
    let client: MaterialHTTPClient
    let extractor: HTMLMaterialExtractor
    private let limits: MaterialHTTPLimits

    init(
        client: MaterialHTTPClient,
        extractor: HTMLMaterialExtractor = HTMLMaterialExtractor(),
        limits: MaterialHTTPLimits = .init()
    ) {
        self.client = client
        self.extractor = extractor
        self.limits = limits
    }

    func acquire(_ source: MaterialSource) async throws -> MaterialAcquisition {
        guard source.descriptor.kind == .publicWebArticle,
              source.kind == .article || source.kind == .socialPost || source.kind == .unknown,
              let sourceURL = source.url
        else {
            throw MaterialDigestPipelineError.unsupportedSource
        }
        let response: (data: Data, response: HTTPURLResponse, finalURL: URL)
        do {
            response = try await client.get(
                sourceURL,
                headers: MaterialRequestHeaders.pageHeaders,
                maxBytes: limits.maxHTMLBytes
            )
        } catch MaterialHTTPClientError.restricted {
            throw MaterialDigestPipelineError.restrictedSource
        } catch MaterialHTTPClientError.tooLarge {
            throw MaterialDigestPipelineError.contextTooLong
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MaterialDigestPipelineError.sourceUnavailable
        }
        let mime = response.response.mimeType?.lowercased()
        guard mime == "text/html" || mime == "application/xhtml+xml" else {
            throw MaterialDigestPipelineError.unsupportedSource
        }
        return .blocks(try extractor.extract(data: response.data, baseURL: response.finalURL))
    }
}

struct BilibiliMaterialAcquirer: MaterialAcquiring {
    let client: MaterialHTTPClient
    private let limits = MaterialHTTPLimits()

    func acquire(_ source: MaterialSource) async throws -> MaterialAcquisition {
        guard let sourceURL = source.url else {
            throw MaterialDigestPipelineError.unsupportedSource
        }
        let page = try await fetchPage(sourceURL)
        guard isBilibiliVideoPage(page.finalURL) else {
            throw MaterialDigestPipelineError.unsupportedSource
        }
        guard let state = BilibiliPageParser.initialState(in: page.html) else {
            throw MaterialDigestPipelineError.sourceUnavailable
        }
        let player = try await fetchPlayer(bvid: state.bvid, cid: state.cid, referer: page.finalURL)
        if let transcript = try await preferredTranscript(from: player, referer: page.finalURL) {
            return .blocks(
                .transcript(transcript, adapterIdentifier: "bilibili")
            )
        }
        var audioURL = player.audioURL
        var audioBytes = player.audioBytes
        if audioURL == nil {
            let playurl = try await fetchPlayurlAudio(bvid: state.bvid, cid: state.cid, referer: page.finalURL)
            audioURL = playurl?.url
            audioBytes = playurl?.bytes
        }
        guard let audioURL else {
            throw MaterialDigestPipelineError.sourceUnavailable
        }
        return .remoteMedia(
            RemoteMediaAsset(
                kind: .audio,
                url: audioURL,
                requestHeaders: [
                    "User-Agent": MaterialRequestHeaders.desktopUserAgent,
                    "Referer": page.finalURL.absoluteString
                ],
                estimatedBytes: audioBytes
            )
        )
    }

    private func fetchPage(_ url: URL) async throws -> (html: String, finalURL: URL) {
        do {
            let result = try await client.get(
                url,
                headers: MaterialRequestHeaders.pageHeaders,
                maxBytes: limits.maxHTMLBytes
            )
            return (String(decoding: result.data, as: UTF8.self), result.finalURL)
        } catch MaterialHTTPClientError.restricted {
            throw MaterialDigestPipelineError.restrictedSource
        } catch MaterialHTTPClientError.tooLarge {
            throw MaterialDigestPipelineError.sourceUnavailable
        } catch {
            throw MaterialDigestPipelineError.sourceUnavailable
        }
    }

    private func fetchPlayer(bvid: String, cid: Int64, referer: URL) async throws -> BilibiliPlayerPayload {
        var components = URLComponents(string: "https://api.bilibili.com/x/player/v2")!
        components.queryItems = [
            URLQueryItem(name: "bvid", value: bvid),
            URLQueryItem(name: "cid", value: String(cid))
        ]
        guard let url = components.url else { throw MaterialDigestPipelineError.sourceUnavailable }
        do {
            let result = try await client.get(
                url,
                headers: MaterialRequestHeaders.pageHeaders(referer: referer),
                maxBytes: limits.maxHTMLBytes
            )
            return try BilibiliPageParser.playerPayload(from: result.data)
        } catch let error as MaterialDigestPipelineError {
            throw error
        } catch MaterialHTTPClientError.restricted {
            throw MaterialDigestPipelineError.restrictedSource
        } catch {
            throw MaterialDigestPipelineError.sourceUnavailable
        }
    }

    private func fetchPlayurlAudio(
        bvid: String,
        cid: Int64,
        referer: URL
    ) async throws -> (url: URL, bytes: Int64?)? {
        var components = URLComponents(string: "https://api.bilibili.com/x/player/playurl")!
        components.queryItems = [
            URLQueryItem(name: "bvid", value: bvid),
            URLQueryItem(name: "cid", value: String(cid)),
            URLQueryItem(name: "fnval", value: "16")
        ]
        guard let url = components.url else { return nil }
        do {
            let result = try await client.get(
                url,
                headers: MaterialRequestHeaders.pageHeaders(referer: referer),
                maxBytes: limits.maxHTMLBytes
            )
            return try BilibiliPageParser.playurlAudio(from: result.data)
        } catch let error as MaterialDigestPipelineError {
            throw error
        } catch MaterialHTTPClientError.restricted {
            throw MaterialDigestPipelineError.restrictedSource
        } catch {
            return nil
        }
    }

    private func preferredTranscript(
        from player: BilibiliPlayerPayload,
        referer: URL
    ) async throws -> TimestampedTranscript? {
        for subtitleURL in player.rankedSubtitleURLs {
            do {
                let result = try await client.get(
                    subtitleURL,
                    headers: MaterialRequestHeaders.pageHeaders(referer: referer),
                    maxBytes: limits.maxSubtitleBytes
                )
                let transcript = try BilibiliPageParser.transcript(from: result.data)
                if BilibiliPageParser.isQualified(transcript) { return transcript }
            } catch MaterialHTTPClientError.restricted {
                continue
            } catch {
                continue
            }
        }
        return nil
    }

    private func isBilibiliVideoPage(_ url: URL) -> Bool {
        SourceKindClassifier.classify(url) == .video
    }
}

struct XiaoyuzhouMaterialAcquirer: MaterialAcquiring {
    let client: MaterialHTTPClient
    private let limits = MaterialHTTPLimits()

    func acquire(_ source: MaterialSource) async throws -> MaterialAcquisition {
        guard let sourceURL = source.url,
              SourceKindClassifier.classify(sourceURL) == .audio
        else {
            throw MaterialDigestPipelineError.unsupportedSource
        }
        let page: (html: String, finalURL: URL)
        do {
            let result = try await client.get(
                sourceURL,
                headers: MaterialRequestHeaders.pageHeaders,
                maxBytes: limits.maxHTMLBytes
            )
            page = (String(decoding: result.data, as: UTF8.self), result.finalURL)
        } catch MaterialHTTPClientError.restricted {
            throw MaterialDigestPipelineError.restrictedSource
        } catch {
            throw MaterialDigestPipelineError.sourceUnavailable
        }
        guard SourceKindClassifier.classify(page.finalURL) == .audio else {
            throw MaterialDigestPipelineError.unsupportedSource
        }
        guard let audioURL = XiaoyuzhouPageParser.audioURL(in: page.html),
              audioURL.scheme?.lowercased() == "https"
        else {
            throw MaterialDigestPipelineError.sourceUnavailable
        }
        return .remoteMedia(
            RemoteMediaAsset(
                kind: .audio,
                url: audioURL,
                requestHeaders: MaterialRequestHeaders.pageHeaders,
                estimatedBytes: nil
            )
        )
    }
}

final class TemporaryMaterialAudioDownloader: MaterialAudioDownloading, @unchecked Sendable {
    let client: MaterialHTTPClient
    let rootDirectory: URL
    private let limits: MaterialHTTPLimits

    init(
        client: MaterialHTTPClient = MaterialHTTPClient(),
        rootDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Jelly-MaterialDigest",
            isDirectory: true
        ),
        limits: MaterialHTTPLimits = .init()
    ) {
        self.client = client
        self.rootDirectory = rootDirectory
        self.limits = limits
    }

    func download(
        _ asset: RemoteAudioAsset,
        runID: MaterialDigestRunID,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let directory = runDirectory(runID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = directory.appendingPathComponent("source-audio.partial")
        let mime: String?
        do {
            mime = try await client.streamDownload(
                asset.url,
                headers: asset.requestHeaders,
                to: partial,
                maxBytes: limits.maxAudioBytes,
                progress: progress
            )
        } catch is CancellationError {
            cleanup(runID: runID)
            throw CancellationError()
        } catch MaterialHTTPClientError.restricted {
            cleanup(runID: runID)
            throw MaterialDigestPipelineError.restrictedSource
        } catch MaterialHTTPClientError.tooLarge {
            cleanup(runID: runID)
            throw MaterialDigestPipelineError.sourceUnavailable
        } catch {
            cleanup(runID: runID)
            throw MaterialDigestPipelineError.sourceUnavailable
        }
        let destination = directory.appendingPathComponent("source-audio\(Self.extension(for: mime))")
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: partial, to: destination)
        return destination
    }

    func cleanup(runID: MaterialDigestRunID) {
        do {
            try FileManager.default.removeItem(at: runDirectory(runID))
        } catch {
            // Cleanup must not change digest outcome; omit absolute paths from diagnostics.
        }
    }

    func cleanupOrphans(keeping activeRunIDs: Set<MaterialDigestRunID>) {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let activeNames = Set(activeRunIDs.map { $0.rawValue.uuidString.lowercased() })
        for directory in directories {
            let name = directory.lastPathComponent.lowercased()
            guard UUID(uuidString: name) != nil, !activeNames.contains(name) else { continue }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func runDirectory(_ runID: MaterialDigestRunID) -> URL {
        rootDirectory.appendingPathComponent(runID.rawValue.uuidString, isDirectory: true)
    }

    private static func `extension`(for mime: String?) -> String {
        let normalized = mime?.split(separator: ";").first.map(String.init)?.lowercased() ?? ""
        switch normalized {
        case "audio/mpeg", "audio/mp3": return ".mp3"
        case "audio/wav", "audio/x-wav": return ".wav"
        case "audio/mp4", "audio/mp4a-latm", "audio/aac": return ".m4a"
        case "video/mp4": return ".mp4"
        case "video/quicktime": return ".mov"
        default: return ".m4a"
        }
    }
}

enum MaterialRequestHeaders {
    static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    static var pageHeaders: [String: String] {
        [
            "User-Agent": desktopUserAgent,
            "Accept": "text/html,application/xhtml+xml,application/json",
            "Accept-Language": "zh-CN,zh;q=0.9"
        ]
    }

    static func pageHeaders(referer: URL) -> [String: String] {
        var headers = pageHeaders
        headers["Referer"] = referer.absoluteString
        return headers
    }
}

enum BilibiliPageParser {
    struct InitialState {
        let bvid: String
        let cid: Int64
    }

    static func initialState(in html: String) -> InitialState? {
        guard let json = extractJSONObject(named: "__INITIAL_STATE__", from: html),
              let object = json as? [String: Any]
        else { return nil }
        let videoData = object["videoData"] as? [String: Any]
        let bvid = (videoData?["bvid"] as? String) ?? (object["bvid"] as? String)
        let cidValue = videoData?["cid"] ?? object["cid"]
        let cid = int64(cidValue)
        guard let bvid, let cid else { return nil }
        return InitialState(bvid: bvid, cid: cid)
    }

    static func playerPayload(from data: Data) throws -> BilibiliPlayerPayload {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MaterialDigestPipelineError.sourceUnavailable
        }
        if let code = object["code"] as? Int, code != 0 {
            if code == -403 || code == 403 { throw MaterialDigestPipelineError.restrictedSource }
            throw MaterialDigestPipelineError.sourceUnavailable
        }
        let dataObject = object["data"] as? [String: Any] ?? [:]
        let subtitleRoot = ((dataObject["subtitle"] as? [String: Any])?["subtitles"] as? [[String: Any]]) ?? []
        let ranked = subtitleRoot
            .compactMap { item -> (Int, URL)? in
                guard let lan = item["lan"] as? String,
                      let rawURL = item["subtitle_url"] as? String,
                      let url = absoluteHTTPSURL(rawURL)
                else { return nil }
                return (subtitleRank(lan), url)
            }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
        let audio = dashAudio(from: dataObject)
        return BilibiliPlayerPayload(
            rankedSubtitleURLs: ranked,
            audioURL: audio?.url,
            audioBytes: audio?.bytes
        )
    }

    static func playurlAudio(from data: Data) throws -> (url: URL, bytes: Int64?) {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MaterialDigestPipelineError.sourceUnavailable
        }
        if let code = object["code"] as? Int, code != 0 {
            if code == -403 || code == 403 { throw MaterialDigestPipelineError.restrictedSource }
            throw MaterialDigestPipelineError.sourceUnavailable
        }
        let dataObject = object["data"] as? [String: Any] ?? [:]
        guard let audio = dashAudio(from: dataObject) else {
            throw MaterialDigestPipelineError.sourceUnavailable
        }
        return audio
    }

    private static func dashAudio(from dataObject: [String: Any]) -> (url: URL, bytes: Int64?)? {
        let audio = ((dataObject["dash"] as? [String: Any])?["audio"] as? [[String: Any]])?.first
        guard let audioURL = (audio?["baseUrl"] as? String).flatMap(absoluteHTTPSURL)
            ?? (audio?["base_url"] as? String).flatMap(absoluteHTTPSURL)
        else { return nil }
        return (audioURL, int64(audio?["size"]))
    }

    static func transcript(from data: Data) throws -> TimestampedTranscript {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = object["body"] as? [[String: Any]]
        else { throw MaterialDigestPipelineError.sourceUnavailable }
        let segments = body.compactMap { item -> TranscriptSegment? in
            let text = (item["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return nil }
            let start = double(item["from"]) ?? 0
            let end = double(item["to"]) ?? start
            return TranscriptSegment(startSeconds: start, endSeconds: max(end, start), text: text)
        }
        return TimestampedTranscript(segments: segments)
    }

    static func isQualified(_ transcript: TimestampedTranscript) -> Bool {
        let nonempty = transcript.segments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard nonempty.count >= 30 else { return false }
        let characters = nonempty.reduce(0) { partial, segment in
            partial + segment.text.unicodeScalars.filter { scalar in
                CharacterSet.letters.contains(scalar) || (0x4E00...0x9FFF).contains(scalar.value)
            }.count
        }
        return characters >= 200
    }

    private static func subtitleRank(_ lan: String) -> Int {
        switch lan.lowercased() {
        case "zh-hans": 0
        case "zh-cn": 1
        case "zh": 2
        case "ai-zh": 3
        default: 100
        }
    }
}

struct BilibiliPlayerPayload {
    var rankedSubtitleURLs: [URL]
    var audioURL: URL?
    var audioBytes: Int64?
}

enum XiaoyuzhouPageParser {
    static func audioURL(in html: String) -> URL? {
        if let og = firstMatch(html, pattern: #"property=["']og:audio["'][^>]*content=["']([^"']+)["']"#)
            ?? firstMatch(html, pattern: #"content=["']([^"']+)["'][^>]*property=["']og:audio["']"#),
           let url = absoluteHTTPSURL(og) {
            return url
        }
        if let jsonLD = extractJSONLDAudioURL(from: html) {
            return jsonLD
        }
        if let next = extractJSONObject(named: "__NEXT_DATA__", from: html),
           let found = firstString(in: next, keys: ["audioUrl"]) ?? enclosureURL(in: next) {
            return absoluteHTTPSURL(found)
        }
        return nil
    }

    private static func extractJSONLDAudioURL(from html: String) -> URL? {
        var search = html[...]
        while let start = search.range(of: "application/ld+json", options: .caseInsensitive) {
            let tail = search[start.upperBound...]
            guard let scriptStart = tail.range(of: ">") else { break }
            guard let scriptEnd = tail.range(of: "</script>", options: .caseInsensitive) else { break }
            let raw = String(tail[scriptStart.upperBound..<scriptEnd.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = raw.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data),
               let url = firstString(in: json, keys: ["contentUrl"]),
               let https = absoluteHTTPSURL(url) {
                return https
            }
            search = tail[scriptEnd.upperBound...]
        }
        return nil
    }
}

private func extractJSONObject(named name: String, from html: String) -> Any? {
    guard let marker = html.range(of: name) else { return nil }
    let tail = html[marker.upperBound...]
    guard let brace = tail.firstIndex(of: "{") else { return nil }
    var depth = 0
    var inString = false
    var escaped = false
    var end = brace
    for index in tail[brace...].indices {
        let character = tail[index]
        if inString {
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                inString = false
            }
            continue
        }
        if character == "\"" {
            inString = true
        } else if character == "{" {
            depth += 1
        } else if character == "}" {
            depth -= 1
            if depth == 0 {
                end = index
                break
            }
        }
    }
    guard depth == 0 else { return nil }
    let raw = sanitizeJavaScriptObjectLiteral(String(tail[brace...end]))
    return try? JSONSerialization.jsonObject(with: Data(raw.utf8))
}

private func sanitizeJavaScriptObjectLiteral(_ raw: String) -> String {
    var output = ""
    output.reserveCapacity(raw.count)
    var inString = false
    var escaped = false
    var index = raw.startIndex
    while index < raw.endIndex {
        let character = raw[index]
        if inString {
            output.append(character)
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                inString = false
            }
            index = raw.index(after: index)
            continue
        }
        if character == "\"" {
            inString = true
            output.append(character)
            index = raw.index(after: index)
            continue
        }
        if replaceJavaScriptLiteral(named: "undefined", with: "null", in: raw, at: &index, output: &output) {
            continue
        }
        if replaceJavaScriptLiteral(named: "NaN", with: "null", in: raw, at: &index, output: &output) {
            continue
        }
        if replaceJavaScriptLiteral(named: "Infinity", with: "null", in: raw, at: &index, output: &output) {
            continue
        }
        output.append(character)
        index = raw.index(after: index)
    }
    return output
}

private func replaceJavaScriptLiteral(
    named token: String,
    with replacement: String,
    in raw: String,
    at index: inout String.Index,
    output: inout String
) -> Bool {
    guard raw[index...].hasPrefix(token) else { return false }
    let end = raw.index(index, offsetBy: token.count, limitedBy: raw.endIndex) ?? raw.endIndex
    let previous = output.last
    let next = end < raw.endIndex ? raw[end] : " "
    let previousIsBoundary = previous == nil || !(previous!.isLetter || previous!.isNumber || previous == "_")
    let nextIsBoundary = !next.isLetter && !next.isNumber && next != "_"
    guard previousIsBoundary, nextIsBoundary else { return false }
    output.append(contentsOf: replacement)
    index = end
    return true
}

private func firstMatch(_ text: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: range),
          match.numberOfRanges > 1,
          let capture = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[capture])
}

private func firstString(in json: Any, keys: [String]) -> String? {
    if let dictionary = json as? [String: Any] {
        for key in keys {
            if key.contains("."),
               let nested = nestedString(in: dictionary, path: key.split(separator: ".").map(String.init)) {
                return nested
            }
            if let value = dictionary[key] as? String { return value }
        }
        for value in dictionary.values {
            if let found = firstString(in: value, keys: keys) { return found }
        }
    } else if let array = json as? [Any] {
        for value in array {
            if let found = firstString(in: value, keys: keys) { return found }
        }
    }
    return nil
}

private func enclosureURL(in json: Any) -> String? {
    if let dictionary = json as? [String: Any] {
        if let enclosure = dictionary["enclosure"] as? [String: Any], let url = enclosure["url"] as? String {
            return url
        }
        for value in dictionary.values {
            if let found = enclosureURL(in: value) { return found }
        }
    } else if let array = json as? [Any] {
        for value in array {
            if let found = enclosureURL(in: value) { return found }
        }
    }
    return nil
}

private func nestedString(in dictionary: [String: Any], path: [String]) -> String? {
    var current: Any = dictionary
    for (index, key) in path.enumerated() {
        guard let object = current as? [String: Any] else { return nil }
        if index == path.count - 1 { return object[key] as? String }
        current = object[key] as Any
    }
    return nil
}

private func absoluteHTTPSURL(_ raw: String) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("//"), let url = URL(string: "https:\(trimmed)") { return url }
    guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https" else { return nil }
    return url
}

private func int64(_ value: Any?) -> Int64? {
    switch value {
    case let number as Int64: return number
    case let number as Int: return Int64(number)
    case let number as Double:
        guard number.isFinite,
              number.rounded(.towardZero) == number,
              number >= Double(Int64.min),
              number <= Double(Int64.max)
        else { return nil }
        return Int64(number)
    case let number as NSNumber:
        let value = number.doubleValue
        guard value.isFinite,
              value.rounded(.towardZero) == value,
              value >= Double(Int64.min),
              value <= Double(Int64.max)
        else { return nil }
        return Int64(value)
    default: return nil
    }
}

private func double(_ value: Any?) -> Double? {
    switch value {
    case let number as Double: return number.isFinite ? number : nil
    case let number as Int: return Double(number)
    case let number as NSNumber:
        let value = number.doubleValue
        return value.isFinite ? value : nil
    default: return nil
    }
}

import Foundation
import Observation
import WorkspaceDomain

/// Where the shared folder lives. The Mac stores a path (iCloud Drive by
/// default); iOS stores a bookmark from the document picker.
enum SyncFolderLocation: Codable, Equatable, Sendable {
    case path(String)
    case bookmark(Data)

    /// Runs `body` with the folder reachable, handling security scope.
    func withAccess<T>(_ body: (URL) throws -> T) throws -> T {
        switch self {
        case let .path(path):
            return try body(URL(fileURLWithPath: path, isDirectory: true))
        case let .bookmark(data):
            var stale = false
            let url = try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try body(url)
        }
    }

    var displayName: String {
        switch self {
        case let .path(path):
            return path.replacingOccurrences(
                of: FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Mobile Documents/com~apple~CloudDocs",
                with: "iCloud Drive"
            )
        case let .bookmark(data):
            var stale = false
            return (try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale))?.lastPathComponent ?? "所选文件夹"
        }
    }
}

struct SyncSettings {
    static let enabledKey = "sync.enabled.v1"
    static let deviceIDKey = "sync.deviceID.v1"
    static let folderKey = "sync.folder.v1"

    let defaults: UserDefaults

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    var deviceID: String {
        if let existing = defaults.string(forKey: Self.deviceIDKey) { return existing }
        let created = UUID().uuidString
        defaults.set(created, forKey: Self.deviceIDKey)
        return created
    }

    var folder: SyncFolderLocation? {
        get {
            defaults.data(forKey: Self.folderKey).flatMap { try? JSONDecoder().decode(SyncFolderLocation.self, from: $0) }
        }
        nonmutating set {
            defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.folderKey)
        }
    }

    #if os(macOS)
    /// iCloud Drive/Jelly 同步 — visible in Files on the iPhone.
    static var defaultMacFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
            .appendingPathComponent("Jelly 同步", isDirectory: true)
    }

    static var iCloudDriveAvailable: Bool {
        FileManager.default.fileExists(
            atPath: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs").path
        )
    }
    #endif
}

/// File layout inside the shared folder:
/// `jelly-sync-v1/devices/<deviceID>.json`, one file per device, each written
/// only by its owner.
enum SyncFolderStore {
    static let directoryName = "jelly-sync-v1"

    static func devicesDirectory(in folder: URL) -> URL {
        folder.appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("devices", isDirectory: true)
    }

    struct PeerRead {
        var documents: [SyncDeviceDocument]
        /// Peers whose file is still downloading from iCloud.
        var pending: Int
        var unreadable: Int
    }

    static func readPeers(in folder: URL, excluding deviceID: String) -> PeerRead {
        let directory = devicesDirectory(in: folder)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var result = PeerRead(documents: [], pending: 0, unreadable: 0)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        for name in names.sorted() {
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                // Evicted iCloud file: ask for it and read it next time.
                let realName = String(name.dropFirst().dropLast(".icloud".count))
                guard realName != "\(deviceID).json" else { continue }
                try? FileManager.default.startDownloadingUbiquitousItem(at: directory.appendingPathComponent(realName))
                result.pending += 1
                continue
            }
            guard name.hasSuffix(".json"), name != "\(deviceID).json" else { continue }
            let url = directory.appendingPathComponent(name)
            var coordinationError: NSError?
            var data: Data?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinated in
                data = try? Data(contentsOf: coordinated)
            }
            guard let data, let document = try? decoder.decode(SyncDeviceDocument.self, from: data) else {
                result.unreadable += 1
                continue
            }
            result.documents.append(document)
        }
        return result
    }

    static func write(_ document: SyncDeviceDocument, in folder: URL) throws {
        let directory = devicesDirectory(in: folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(document)
        let url = directory.appendingPathComponent("\(document.deviceID).json")
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinated in
            do { try data.write(to: coordinated, options: .atomic) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
    }
}

@MainActor
@Observable
final class WorkspaceSyncService {
    enum Status: Equatable {
        case off
        case idle
        case syncing
        case synced(Date, String)
        case failed(String)
    }

    private let store: WorkspaceStore
    private let metaURL: URL
    let settings: SyncSettings
    let deviceName: String
    private let clock: @Sendable () -> Date
    private var pendingSync: Task<Void, Never>?
    private var observer: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var isSyncing = false

    private(set) var status: Status = .off
    private(set) var peerNames: [String] = []
    private(set) var lastConflictCopies: [String] = []

    init(
        store: WorkspaceStore,
        dataRoot: URL,
        settings: SyncSettings,
        deviceName: String,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        metaURL = dataRoot.appendingPathComponent("sync", isDirectory: true).appendingPathComponent("meta.json")
        self.settings = settings
        self.deviceName = deviceName
        self.clock = clock
        status = settings.isEnabled ? .idle : .off
    }

    func enable(folder: SyncFolderLocation) async {
        settings.folder = folder
        settings.isEnabled = true
        status = .idle
        await syncNow()
    }

    func disable() {
        settings.isEnabled = false
        pendingSync?.cancel()
        status = .off
    }

    /// Syncs a little after edits settle, every two minutes, and whenever the
    /// caller asks (launch, returning to the foreground).
    func start() {
        guard observer == nil else { return }
        observer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let store = self?.store else { return }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = store.statePublicationGeneration
                    } onChange: {
                        continuation.resume()
                    }
                }
                guard let self, !self.isSyncing else { continue }
                self.scheduleSync(after: .seconds(8))
            }
        }
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.scheduleSync(after: .seconds(2))
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    func scheduleSync(after delay: Duration = .seconds(2)) {
        guard settings.isEnabled else { return }
        pendingSync?.cancel()
        pendingSync = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    func syncNow() async {
        guard settings.isEnabled, !isSyncing else { return }
        guard let folder = settings.folder else {
            status = .failed("还没有选同步文件夹。")
            return
        }
        guard store.phase == .ready else { return }
        isSyncing = true
        status = .syncing
        defer { isSyncing = false }
        let deviceID = settings.deviceID
        let now = clock()
        do {
            let peers = try folder.withAccess { url in
                try FileManager.default.createDirectory(
                    at: SyncFolderStore.devicesDirectory(in: url),
                    withIntermediateDirectories: true
                )
                return SyncFolderStore.readPeers(in: url, excluding: deviceID)
            }
            peerNames = peers.documents.map(\.deviceName).sorted()
            let snapshot = store.state
            let meta = loadMeta(deviceID: deviceID)
            let name = deviceName
            let reconciliation = try await Task.detached(priority: .utility) {
                try WorkspaceSyncEngine.reconcile(
                    local: snapshot,
                    meta: meta,
                    peers: peers.documents,
                    deviceID: deviceID,
                    deviceName: name,
                    now: now
                )
            }.value
            // The user kept typing while we merged: try again shortly.
            guard store.state == snapshot else {
                scheduleSync(after: .seconds(3))
                status = .idle
                return
            }
            if WorkspaceContentSnapshot(state: reconciliation.state) != WorkspaceContentSnapshot(state: snapshot) {
                let merged = reconciliation.state
                let outcome = try await store.sendWorkspace(
                    .restoreContent(WorkspaceRestoreContentPayload(
                        content: WorkspaceContentSnapshot(state: merged),
                        sourceRevisionHighWatermark: merged.revision,
                        sourceNoteRevisions: merged.notes.mapValues(\.revision)
                    )),
                    undoLabel: "同步"
                )
                switch outcome {
                case .committed, .noChange:
                    break
                default:
                    status = .failed("本机数据暂时不能写入，同步稍后重试。")
                    return
                }
            }
            try saveMeta(reconciliation.meta)
            try folder.withAccess { url in try SyncFolderStore.write(reconciliation.document, in: url) }
            lastConflictCopies = reconciliation.conflictCopies
            var summary = peers.documents.isEmpty ? "还没有其他设备" : "与 \(peers.documents.map(\.deviceName).joined(separator: "、")) 一致"
            if peers.pending > 0 { summary += "（\(peers.pending) 个设备的文件还在从 iCloud 下载）" }
            if !reconciliation.conflictCopies.isEmpty {
                summary += "；\(reconciliation.conflictCopies.count) 篇笔记两边同时改过，已保留冲突副本"
            }
            status = .synced(now, summary)
        } catch WorkspaceSyncError.unsupportedFormat {
            status = .failed("另一台设备的 Jelly 版本更新，请先升级这台的 Jelly。")
        } catch WorkspaceSyncError.cannotReconcile {
            status = .failed("两边的数据无法自动合并，本机数据没有改动。")
        } catch {
            status = .failed("同步文件夹暂时无法读写：\(error.localizedDescription)")
        }
    }

    private func loadMeta(deviceID: String) -> SyncLocalMeta? {
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(SyncLocalMeta.self, from: data),
              meta.deviceID == deviceID
        else { return nil }
        return meta
    }

    private func saveMeta(_ meta: SyncLocalMeta) throws {
        try FileManager.default.createDirectory(at: metaURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(meta).write(to: metaURL, options: .atomic)
    }
}

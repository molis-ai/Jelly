import Darwin
import Foundation

enum AppDataProfileError: Error, Equatable, Sendable {
    case invalidConfiguration
}

enum AppDataProfile: String, Equatable, Sendable {
    case daily
    case preview

    static let infoDictionaryKey = "JellyDataProfile"
    static let dailyBundleIdentifier = "com.oreal.personalcalendar"
    static let previewBundleIdentifier = "com.oreal.personalcalendar.preview"

    static func resolve(configuredValue: Any?, bundleIdentifier: String?) throws -> AppDataProfile {
        let profile: AppDataProfile
        if let configuredValue {
            guard let value = configuredValue as? String,
                  let configuredProfile = AppDataProfile(rawValue: value) else {
                throw AppDataProfileError.invalidConfiguration
            }
            profile = configuredProfile
        } else {
            profile = .daily
        }

        switch bundleIdentifier {
        case previewBundleIdentifier:
            guard configuredValue != nil, profile == .preview else {
                throw AppDataProfileError.invalidConfiguration
            }
        case dailyBundleIdentifier:
            guard profile == .daily else {
                throw AppDataProfileError.invalidConfiguration
            }
        default:
            throw AppDataProfileError.invalidConfiguration
        }
        return profile
    }

    static func bundled(in bundle: Bundle = .main) throws -> AppDataProfile {
        try resolve(
            configuredValue: bundle.object(forInfoDictionaryKey: infoDictionaryKey),
            bundleIdentifier: bundle.bundleIdentifier
        )
    }

    var applicationSupportDirectoryName: String {
        switch self {
        case .daily: "PersonalCalendar"
        case .preview: "PersonalCalendarPreview"
        }
    }
}

struct AppDataURLs: Equatable, Sendable {
    let root: URL
    let mainDocument: URL
    let migrationSnapshotDirectory: URL
    let recoveryManifest: URL
    let draftJournal: URL
    let rollbackDirectory: URL
    let automaticRecoveryDirectory: URL
    let searchIndex: URL
}

enum AppDataDirectoryResolverError: Error, Equatable, Sendable {
    case invalidOverride
    case inaccessibleDirectory
    case profileCollision
}

enum AppDataDirectoryResolver {
    static func resolve(
        profile: AppDataProfile = .daily,
        environment: [String: String],
        fileManager: FileManager = .default,
        defaultApplicationSupportURL: URL? = nil
    ) throws -> AppDataURLs {
        let root: URL
        if let supplied = environment["JELLY_ACCEPTANCE_DATA_DIRECTORY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !supplied.isEmpty {
            guard !supplied.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
                throw AppDataDirectoryResolverError.invalidOverride
            }
            guard (supplied as NSString).isAbsolutePath else {
                throw AppDataDirectoryResolverError.invalidOverride
            }
            let requested = URL(fileURLWithPath: supplied, isDirectory: true)
            let url = requested.standardizedFileURL
            guard requested.path.hasPrefix("/"), url.path != "/" else {
                throw AppDataDirectoryResolverError.invalidOverride
            }
            root = url
        } else {
            guard let support = defaultApplicationSupportURL
                ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            else {
                throw AppDataDirectoryResolverError.inaccessibleDirectory
            }
            root = support.appendingPathComponent(profile.applicationSupportDirectoryName, isDirectory: true).standardizedFileURL
        }
        if profile == .preview {
            guard let support = defaultApplicationSupportURL
                ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            else {
                throw AppDataDirectoryResolverError.inaccessibleDirectory
            }
            let dailyRoot = support.appendingPathComponent(
                AppDataProfile.daily.applicationSupportDirectoryName,
                isDirectory: true
            ).standardizedFileURL
            guard !pathsOverlapCaseInsensitively(root, dailyRoot) else {
                throw AppDataDirectoryResolverError.profileCollision
            }
        }
        guard root.path != "/" else { throw AppDataDirectoryResolverError.invalidOverride }
        try rejectExistingSymlinkAncestors(of: root, fileManager: fileManager)
        if fileManager.fileExists(atPath: root.path) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  root.resolvingSymlinksInPath().standardizedFileURL == root
            else { throw AppDataDirectoryResolverError.inaccessibleDirectory }
        } else {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        }
        try rejectExistingSymlinkAncestors(of: root, fileManager: fileManager)
        guard root.resolvingSymlinksInPath().standardizedFileURL == root,
              fileManager.isWritableFile(atPath: root.path), fileManager.isReadableFile(atPath: root.path) else {
            throw AppDataDirectoryResolverError.inaccessibleDirectory
        }
        try validateSearchableDirectoryWithoutFollowingTheFinalPathComponent(root)
        return .init(
            root: root,
            mainDocument: root.appendingPathComponent("calendar-v1.json"),
            migrationSnapshotDirectory: root.appendingPathComponent("calendar-v1.recovery-snapshots", isDirectory: true),
            recoveryManifest: root.appendingPathComponent("calendar-v1.recovery-manifest.json"),
            draftJournal: root.appendingPathComponent("calendar-v1.draft-journal.json"),
            rollbackDirectory: root.appendingPathComponent("restore-rollbacks", isDirectory: true),
            automaticRecoveryDirectory: root.appendingPathComponent("automatic-recovery", isDirectory: true),
            searchIndex: root.appendingPathComponent("workspace-search-v1.json")
        )
    }

    private static func pathsOverlapCaseInsensitively(_ first: URL, _ second: URL) -> Bool {
        let firstPath = first.standardizedFileURL.path
            .precomposedStringWithCanonicalMapping
            .lowercased()
        let secondPath = second.standardizedFileURL.path
            .precomposedStringWithCanonicalMapping
            .lowercased()
        return firstPath == secondPath
            || firstPath.hasPrefix(secondPath + "/")
            || secondPath.hasPrefix(firstPath + "/")
    }

    /// Inspect every existing component before `createDirectory` is allowed to
    /// follow it.  This prevents a missing tail below an attacker-controlled
    /// symlink from being created outside the requested root.
    private static func rejectExistingSymlinkAncestors(of root: URL, fileManager: FileManager) throws {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in root.standardizedFileURL.pathComponents.dropFirst() {
            current.appendPathComponent(component, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: current.path, isDirectory: &isDirectory) else { break }
            // `/var` is the platform's canonical compatibility alias on
            // macOS. Foundation preserves it as the same sandbox root; all
            // caller-controlled components below it still receive no-follow
            // inspection.
            if current.path != "/var",
               (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw AppDataDirectoryResolverError.inaccessibleDirectory
            }
            guard isDirectory.boolValue || current.standardizedFileURL == root.standardizedFileURL else {
                throw AppDataDirectoryResolverError.inaccessibleDirectory
            }
        }
    }

    /// Opening the final path with `O_NOFOLLOW` closes the check/use gap left
    /// by Foundation's path-based readability APIs.  A directory needs execute
    /// (search) permission as well as read/write permission before it can host
    /// the workspace document and its recovery sidecars.
    private static func validateSearchableDirectoryWithoutFollowingTheFinalPathComponent(_ root: URL) throws {
        let fileDescriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fileDescriptor >= 0 else {
            throw AppDataDirectoryResolverError.inaccessibleDirectory
        }
        defer { _ = close(fileDescriptor) }

        var metadata = stat()
        guard fstat(fileDescriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              faccessat(fileDescriptor, ".", X_OK, 0) == 0 else {
            throw AppDataDirectoryResolverError.inaccessibleDirectory
        }
    }
}

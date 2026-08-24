import Foundation
import Testing
@testable import CalendarApp

@Suite("AppDataDirectoryResolverTests")
struct AppDataDirectoryResolverTests {
    @Test func bundledDataProfileRequiresAnExactPackagedIdentity() throws {
        #expect(try AppDataProfile.resolve(
            configuredValue: "daily",
            bundleIdentifier: "com.oreal.personalcalendar"
        ) == .daily)
        #expect(try AppDataProfile.resolve(
            configuredValue: "preview",
            bundleIdentifier: "com.oreal.personalcalendar.preview"
        ) == .preview)
        #expect(throws: AppDataProfileError.invalidConfiguration) {
            _ = try AppDataProfile.resolve(
                configuredValue: nil,
                bundleIdentifier: "com.oreal.personalcalendar.preview"
            )
        }
        #expect(throws: AppDataProfileError.invalidConfiguration) {
            _ = try AppDataProfile.resolve(
                configuredValue: "daily",
                bundleIdentifier: "com.oreal.personalcalendar.preview"
            )
        }
        #expect(throws: AppDataProfileError.invalidConfiguration) {
            _ = try AppDataProfile.resolve(
                configuredValue: "preview",
                bundleIdentifier: "com.oreal.personalcalendar"
            )
        }
        #expect(throws: AppDataProfileError.invalidConfiguration) {
            _ = try AppDataProfile.resolve(configuredValue: "development", bundleIdentifier: nil)
        }
        #expect(throws: AppDataProfileError.invalidConfiguration) {
            _ = try AppDataProfile.resolve(configuredValue: 1, bundleIdentifier: nil)
        }
        #expect(throws: AppDataProfileError.invalidConfiguration) {
            _ = try AppDataProfile.resolve(configuredValue: nil, bundleIdentifier: nil)
        }
        #expect(throws: AppDataProfileError.invalidConfiguration) {
            _ = try AppDataProfile.resolve(configuredValue: "daily", bundleIdentifier: nil)
        }
    }

    @Test func rejectsRootAndRelativeAcceptanceDirectories() throws {
        #expect(throws: AppDataDirectoryResolverError.invalidOverride) {
            _ = try AppDataDirectoryResolver.resolve(environment: ["JELLY_ACCEPTANCE_DATA_DIRECTORY": "/"])
        }
        #expect(throws: AppDataDirectoryResolverError.invalidOverride) {
            _ = try AppDataDirectoryResolver.resolve(environment: ["JELLY_ACCEPTANCE_DATA_DIRECTORY": "relative"])
        }
    }

    @Test func buildsAllSidecarsUnderStandardizedAbsoluteOverride() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-6b-resolver-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try AppDataDirectoryResolver.resolve(
            environment: ["JELLY_ACCEPTANCE_DATA_DIRECTORY": root.path]
        )
        #expect(urls.root.isFileURL)
        #expect(urls.mainDocument.deletingLastPathComponent() == urls.root)
        #expect(urls.draftJournal.path.hasPrefix(urls.root.path + "/"))
        #expect(FileManager.default.fileExists(atPath: urls.root.path))
    }

    @Test func emptyOverrideUsesThePersonalCalendarApplicationSupportDefaultWithoutTouchingHome() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-6b-default-support-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let urls = try AppDataDirectoryResolver.resolve(
            environment: ["JELLY_ACCEPTANCE_DATA_DIRECTORY": "   "],
            defaultApplicationSupportURL: support
        )

        #expect(urls.root == support.appendingPathComponent("PersonalCalendar", isDirectory: true).standardizedFileURL)
        #expect(urls.mainDocument == urls.root.appendingPathComponent("calendar-v1.json"))
        #expect(FileManager.default.fileExists(atPath: urls.root.path))
    }

    @Test func dailyAndPreviewProfilesUseDifferentApplicationSupportDirectories() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-profile-support-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }

        let daily = try AppDataDirectoryResolver.resolve(
            profile: .daily,
            environment: [:],
            defaultApplicationSupportURL: support
        )
        let preview = try AppDataDirectoryResolver.resolve(
            profile: .preview,
            environment: [:],
            defaultApplicationSupportURL: support
        )

        #expect(daily.root == support.appendingPathComponent("PersonalCalendar", isDirectory: true).standardizedFileURL)
        #expect(preview.root == support.appendingPathComponent("PersonalCalendarPreview", isDirectory: true).standardizedFileURL)
        #expect(daily.root != preview.root)
    }

    @Test func previewRejectsAnOverridePointingAtTheDailyDataDirectory() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-profile-collision-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let dailyRoot = support.appendingPathComponent("PersonalCalendar", isDirectory: true)

        #expect(throws: AppDataDirectoryResolverError.self) {
            _ = try AppDataDirectoryResolver.resolve(
                profile: .preview,
                environment: ["JELLY_ACCEPTANCE_DATA_DIRECTORY": dailyRoot.path],
                defaultApplicationSupportURL: support
            )
        }
        #expect(FileManager.default.fileExists(atPath: dailyRoot.path) == false)
    }

    @Test func previewRejectsCaseAliasesAndDescendantsOfTheDailyDataDirectory() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-profile-overlap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let dailyRoot = support.appendingPathComponent("PersonalCalendar", isDirectory: true)
        let caseAlias = support.appendingPathComponent("personalcalendar", isDirectory: true)
        let nested = dailyRoot.appendingPathComponent("Preview", isDirectory: true)

        #expect(throws: AppDataDirectoryResolverError.profileCollision) {
            _ = try AppDataDirectoryResolver.resolve(
                profile: .preview,
                environment: ["JELLY_ACCEPTANCE_DATA_DIRECTORY": caseAlias.path],
                defaultApplicationSupportURL: support
            )
        }
        #expect(throws: AppDataDirectoryResolverError.profileCollision) {
            _ = try AppDataDirectoryResolver.resolve(
                profile: .preview,
                environment: ["JELLY_ACCEPTANCE_DATA_DIRECTORY": nested.path],
                defaultApplicationSupportURL: support
            )
        }
        #expect(FileManager.default.fileExists(atPath: dailyRoot.path) == false)
    }

    @Test func rejectsOverrideThatEscapesThroughASymlink() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-parent-\(UUID().uuidString)", isDirectory: true)
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-target-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent); try? FileManager.default.removeItem(at: target) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = parent.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: AppDataDirectoryResolverError.inaccessibleDirectory) {
            _ = try AppDataDirectoryResolver.resolve(environment: ["JELLY_ACCEPTANCE_DATA_DIRECTORY": link.path])
        }
    }

    @Test func rejectsASymlinkAncestorBeforeCreatingANonexistentDescendantOutsideTheRequestedTree() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-ancestor-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-outside-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = parent.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let requested = link.appendingPathComponent("not-created/yet", isDirectory: true)

        #expect(throws: AppDataDirectoryResolverError.inaccessibleDirectory) {
            _ = try AppDataDirectoryResolver.resolve(environment: ["JELLY_ACCEPTANCE_DATA_DIRECTORY": requested.path])
        }
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("not-created").path) == false)
    }

    @Test func rejectsControlCharactersInsteadOfCreatingAnUnexpectedDirectory() throws {
        let path = FileManager.default.temporaryDirectory.path + "/jelly-6b-\u{0001}-control"
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(throws: AppDataDirectoryResolverError.invalidOverride) {
            _ = try AppDataDirectoryResolver.resolve(environment: ["JELLY_ACCEPTANCE_DATA_DIRECTORY": path])
        }
        #expect(FileManager.default.fileExists(atPath: path) == false)
    }

    @Test func rejectsAnExistingFileInsteadOfTreatingItAsTheSidecarDirectory() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-file-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not a directory".utf8).write(to: file)

        #expect(throws: AppDataDirectoryResolverError.inaccessibleDirectory) {
            _ = try AppDataDirectoryResolver.resolve(environment: ["JELLY_ACCEPTANCE_DATA_DIRECTORY": file.path])
        }
    }

    @Test func rejectsAnUnsearchableDirectoryButAcceptsAnOwnerSearchableDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-6c-searchable-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.path)
        #expect(throws: AppDataDirectoryResolverError.inaccessibleDirectory) {
            _ = try AppDataDirectoryResolver.resolve(environment: ["JELLY_ACCEPTANCE_DATA_DIRECTORY": root.path])
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let urls = try AppDataDirectoryResolver.resolve(environment: ["JELLY_ACCEPTANCE_DATA_DIRECTORY": root.path])
        #expect(urls.root == root.standardizedFileURL)
    }
}

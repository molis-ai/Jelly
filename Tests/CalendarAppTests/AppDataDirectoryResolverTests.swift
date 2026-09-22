import Foundation
import Testing
@testable import CalendarApp

@Suite("AppDataDirectoryResolverTests")
struct AppDataDirectoryResolverTests {
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

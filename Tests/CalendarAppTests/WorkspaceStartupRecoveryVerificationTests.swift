import CalendarDomain
import CalendarPersistence
import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("WorkspaceStartupRecoveryVerificationTests")
@MainActor
struct WorkspaceStartupRecoveryVerificationTests {
    @Test func matchingDurableContentClearsOnlyTheExactBareRecord() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let beforeBytes = try Data(contentsOf: fixture.documentURL)
        #expect(fixture.entry.noteSnapshot.revision != fixture.persisted.revision)
        #expect(fixture.entry.noteSnapshotChecksum == (try WorkspaceChecksum.noteSnapshotChecksum(fixture.persisted)))

        await fixture.store.load()

        #expect(fixture.store.phase == .ready)
        #expect(try await fixture.journal.current()?.records.isEmpty == true)
        #expect(fixture.store.state.notes[fixture.persisted.id] == fixture.persisted)
        #expect(try Data(contentsOf: fixture.documentURL) == beforeBytes)
    }

    @Test func unreadablePrimaryKeepsBareProtectionDespiteMatchingCachedContent() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let journalBytes = try Data(contentsOf: fixture.journalURL)
        let preservedPrimary = fixture.directory.appendingPathComponent("preserved-primary.json")
        try FileManager.default.moveItem(at: fixture.documentURL, to: preservedPrimary)
        try FileManager.default.createDirectory(at: fixture.documentURL, withIntermediateDirectories: false)

        await fixture.store.load()

        #expect(fixture.store.phase == .unreadablePrimaryLoadFailed)
        #expect(fixture.store.state.notes[fixture.persisted.id] == fixture.persisted)
        #expect(try Data(contentsOf: fixture.journalURL) == journalBytes)
        #expect(try await fixture.journal.current()?.records.first?.entry == fixture.entry)
        #expect(try WorkspaceDocumentCodec.decode(Data(contentsOf: preservedPrimary)).state == fixture.state)
    }

    @Test func changedPrimaryKeepsBareProtectionDespiteMatchingCachedContent() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let journalBytes = try Data(contentsOf: fixture.journalURL)
        var external = fixture.state
        external.revision += 1
        external.notes[fixture.persisted.id]?.revision = external.revision
        external.notes[fixture.persisted.id]?.title = "外部写入的版本"
        let externalBytes = try WorkspaceDocumentCodec.encode(external)
        try externalBytes.write(to: fixture.documentURL, options: .atomic)

        await fixture.store.load()

        #expect(fixture.store.phase == .externalSourceChanged(.externalBytesChanged))
        #expect(fixture.store.state.notes[fixture.persisted.id] == fixture.persisted)
        #expect(try Data(contentsOf: fixture.journalURL) == journalBytes)
        #expect(try await fixture.journal.current()?.records.first?.entry == fixture.entry)
        #expect(try Data(contentsOf: fixture.documentURL) == externalBytes)
    }

    @Test func matchingSeedWithoutPrimaryRemainsARecoveryCandidate() async throws {
        let fixture = try await makeFixture(persistPrimary: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let journalBytes = try Data(contentsOf: fixture.journalURL)

        await fixture.store.load()

        guard case let .needsDraftRecovery(candidates) = fixture.store.phase else {
            Issue.record("An in-memory seed is not proof that protected content is durable")
            return
        }
        #expect(candidates.count == 1)
        #expect(candidates.first?.draft == fixture.entry.noteSnapshot)
        #expect(try Data(contentsOf: fixture.journalURL) == journalBytes)
        #expect(try await fixture.journal.current()?.records.first?.entry == fixture.entry)
        #expect(!FileManager.default.fileExists(atPath: fixture.documentURL.path))
    }

    private struct Fixture {
        let directory: URL
        let documentURL: URL
        let journalURL: URL
        let persisted: Note
        let state: WorkspaceState
        let entry: DraftJournalEntry
        let journal: DraftJournalRepository
        let store: WorkspaceStore
    }

    private func makeFixture(persistPrimary: Bool = true) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "jelly-startup-verification-\(UUID())", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let documentURL = directory.appendingPathComponent("workspace.json")
        let journalURL = directory.appendingPathComponent("drafts.json")
        let calendar = CalendarState.empty(uncategorizedID: UUID(), now: .distantPast)
        var note = Note.empty(categoryID: calendar.uncategorizedID, now: .distantPast)
        note.title = "需要持久化证据的草稿"
        note.revision = 1
        var state = WorkspaceState.empty(calendar: calendar)
        state.revision = 1
        state.notes[note.id] = note
        if persistPrimary { try WorkspaceDocumentCodec.encode(state).write(to: documentURL) }
        let seed = state
        let repository = JSONWorkspaceRepository(documentURL: documentURL, seed: { seed })
        let journal = DraftJournalRepository(fileURL: journalURL)
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository, journal: journal)
        await store.load()
        #expect(store.phase == .ready)
        var draft = note
        draft.revision = 2
        draft.updatedAt = Date(timeIntervalSince1970: 50)
        let submission = NoteDraftSubmission(
            noteID: note.id, editSessionID: UUID(), baseNoteRevision: note.revision,
            baseNoteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(note),
            baseSnapshot: note, baseLinkedTaskBlockLinks: [], draftGeneration: 1,
            snapshot: draft, noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(draft),
            modifiedFields: [], linkedBlockDeletionDispositions: [:]
        )
        let entry = try DraftJournalCoordinator.entry(submission: submission, workspaceRevision: state.revision, clock: { .distantPast })
        try await journal.persist(entry)
        return .init(directory: directory, documentURL: documentURL, journalURL: journalURL, persisted: note,
            state: state, entry: entry, journal: journal, store: store)
    }
}

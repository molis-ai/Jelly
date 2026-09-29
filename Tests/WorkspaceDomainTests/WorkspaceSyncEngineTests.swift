import CalendarDomain
import Foundation
import Testing
@testable import WorkspaceDomain

/// A device in a simulated shared folder.
private struct Device {
    let id: String
    var state: WorkspaceState
    var meta: SyncLocalMeta?
    var published: SyncDeviceDocument?

    init(_ id: String, state: WorkspaceState) {
        self.id = id
        self.state = state
    }

    mutating func sync(with folder: [SyncDeviceDocument], at now: Date) throws -> SyncReconciliation {
        let result = try WorkspaceSyncEngine.reconcile(
            local: state,
            meta: meta,
            peers: folder,
            deviceID: id,
            deviceName: id,
            now: now
        )
        state = result.state
        meta = result.meta
        published = result.document
        return result
    }
}

@Suite("WorkspaceSyncEngineTests")
struct WorkspaceSyncEngineTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let day = CalendarDate(year: 2026, month: 10, day: 1)!

    private func emptyState(uncategorized: UUID = UUID()) -> WorkspaceState {
        WorkspaceState.empty(calendar: .empty(uncategorizedID: uncategorized, now: t0))
    }

    private func item(_ title: String, in state: WorkspaceState, id: UUID = UUID(), at time: Date? = nil) throws -> CalendarItem {
        try CalendarItem(
            id: id,
            kind: .task,
            title: title,
            categoryID: state.calendar.uncategorizedID,
            schedule: CalendarSchedule(startDate: day, endDate: day, startTime: nil, endTime: nil),
            creationTimeZoneIdentifier: "UTC",
            completedAt: nil,
            createdAt: time ?? t0,
            updatedAt: time ?? t0
        )
    }

    private func note(_ title: String, text: String, in state: WorkspaceState, id: NoteID = NoteID()) -> Note {
        Note(
            id: id,
            title: title,
            document: BlockDocument(blocks: [.init(id: BlockID(), kind: .paragraph, inlineContent: .plain(text), taskState: nil, indentLevel: 0)]),
            categoryID: state.calendar.uncategorizedID,
            archivedAt: nil,
            revision: 1,
            createdAt: t0,
            updatedAt: t0
        )
    }

    private func titles(_ state: WorkspaceState) -> [String] {
        state.calendar.items.values.map(\.title).sorted()
    }

    @Test func twoDevicesWithExistingDataJoinAndConverge() throws {
        var mac = Device("mac", state: emptyState())
        var phone = Device("phone", state: emptyState())
        mac.state.calendar.items[UUID()] = nil
        let macItem = try item("Mac 上的事", in: mac.state)
        mac.state.calendar.items[macItem.id] = macItem
        let phoneItem = try item("手机上的事", in: phone.state)
        phone.state.calendar.items[phoneItem.id] = phoneItem
        let work = CalendarCategory(id: UUID(), name: "工作", colorHex: "#123456", sortIndex: 1, createdAt: t0, updatedAt: t0)
        let work2 = CalendarCategory(id: UUID(), name: "工作", colorHex: "#654321", sortIndex: 1, createdAt: t0, updatedAt: t0)
        mac.state.calendar.categories[work.id] = work
        phone.state.calendar.categories[work2.id] = work2
        phone.state.calendar.items[phoneItem.id]?.categoryID = work2.id

        _ = try mac.sync(with: [], at: t0)
        _ = try phone.sync(with: [mac.published!], at: t0.addingTimeInterval(10))
        _ = try mac.sync(with: [phone.published!], at: t0.addingTimeInterval(20))

        #expect(titles(mac.state) == ["Mac 上的事", "手机上的事"])
        #expect(titles(phone.state) == titles(mac.state))
        #expect(mac.state.calendar.uncategorizedID == phone.state.calendar.uncategorizedID)
        let workCategories = mac.state.calendar.categories.values.filter { $0.name == "工作" }
        #expect(workCategories.count == 1)
        #expect(mac.state.calendar.items[phoneItem.id]?.categoryID == workCategories.first?.id)
        #expect(try WorkspaceSyncRecords.records(of: mac.state) == WorkspaceSyncRecords.records(of: phone.state))
        try WorkspaceValidator.validate(mac.state)
        try WorkspaceValidator.validate(phone.state)
    }

    @Test func editsAndDeletesTravelBothWays() throws {
        let shared = emptyState()
        var mac = Device("mac", state: shared)
        var phone = Device("phone", state: shared)
        let a = try item("交房租", in: shared)
        let b = try item("看牙", in: shared)
        mac.state.calendar.items[a.id] = a
        mac.state.calendar.items[b.id] = b
        _ = try mac.sync(with: [], at: t0)
        _ = try phone.sync(with: [mac.published!], at: t0.addingTimeInterval(1))
        #expect(titles(phone.state) == ["交房租", "看牙"])

        phone.state.calendar.items[a.id]?.title = "交房租（已问房东）"
        mac.state.calendar.items[b.id] = nil
        _ = try phone.sync(with: [mac.published!], at: t0.addingTimeInterval(5))
        _ = try mac.sync(with: [phone.published!], at: t0.addingTimeInterval(6))
        _ = try phone.sync(with: [mac.published!], at: t0.addingTimeInterval(7))

        #expect(titles(mac.state) == ["交房租（已问房东）"])
        #expect(titles(phone.state) == ["交房租（已问房东）"])

        // A stale peer file must not resurrect what was deleted later.
        let staleFolder = [mac.published!]
        _ = try phone.sync(with: staleFolder, at: t0.addingTimeInterval(8))
        #expect(titles(phone.state) == ["交房租（已问房东）"])
    }

    @Test func concurrentNoteEditsKeepBothVersions() throws {
        let shared = emptyState()
        var mac = Device("mac", state: shared)
        var phone = Device("phone", state: shared)
        let original = note("周计划", text: "原文", in: shared)
        mac.state.notes[original.id] = original
        _ = try mac.sync(with: [], at: t0)
        _ = try phone.sync(with: [mac.published!], at: t0.addingTimeInterval(1))

        mac.state.notes[original.id] = note("周计划", text: "Mac 上写的", in: shared, id: original.id)
        phone.state.notes[original.id] = note("周计划", text: "手机上写的", in: shared, id: original.id)
        let macResult = try mac.sync(with: [phone.published!], at: t0.addingTimeInterval(10))
        let phoneResult = try phone.sync(with: [mac.published!], at: t0.addingTimeInterval(11))
        _ = try mac.sync(with: [phone.published!], at: t0.addingTimeInterval(12))

        let texts = Set(mac.state.notes.values.map { $0.document.blocks[0].inlineContent.spans.map(\.text).joined() })
        #expect(texts == ["Mac 上写的", "手机上写的"])
        #expect(mac.state.notes.values.contains { $0.title == "周计划（冲突副本）" })
        #expect(macResult.conflictCopies.count + phoneResult.conflictCopies.count == 1)
        #expect(Set(phone.state.notes.keys) == Set(mac.state.notes.keys))
    }

    @Test func sequentialEditsDoNotCreateConflictCopies() throws {
        let shared = emptyState()
        var mac = Device("mac", state: shared)
        var phone = Device("phone", state: shared)
        let original = note("清单", text: "v1", in: shared)
        mac.state.notes[original.id] = original
        _ = try mac.sync(with: [], at: t0)
        _ = try phone.sync(with: [mac.published!], at: t0.addingTimeInterval(1))
        phone.state.notes[original.id] = note("清单", text: "v2", in: shared, id: original.id)
        _ = try phone.sync(with: [mac.published!], at: t0.addingTimeInterval(2))
        _ = try mac.sync(with: [phone.published!], at: t0.addingTimeInterval(3))
        mac.state.notes[original.id] = note("清单", text: "v3", in: shared, id: original.id)
        _ = try mac.sync(with: [phone.published!], at: t0.addingTimeInterval(4))
        let result = try phone.sync(with: [mac.published!], at: t0.addingTimeInterval(5))
        #expect(result.conflictCopies.isEmpty)
        #expect(phone.state.notes.count == 1)
        #expect(phone.state.notes[original.id]?.document.blocks[0].inlineContent.spans.map(\.text).joined() == "v3")
    }

    @Test func referencesToThingsDeletedElsewhereAreRepaired() throws {
        let shared = emptyState()
        var mac = Device("mac", state: shared)
        var phone = Device("phone", state: shared)
        let target = try item("周会", in: shared)
        let doc = note("会议记录", text: "…", in: shared)
        mac.state.calendar.items[target.id] = target
        mac.state.notes[doc.id] = doc
        _ = try mac.sync(with: [], at: t0)
        _ = try phone.sync(with: [mac.published!], at: t0.addingTimeInterval(1))

        // Phone links the note to the item while the Mac deletes the note.
        phone.state.calendarNoteRelations.baselines[.item(target.id)] = CalendarNoteSet(primaryNoteID: doc.id, referenceNoteIDs: [])
        try WorkspaceValidator.validate(phone.state)
        mac.state.notes[doc.id] = nil
        _ = try mac.sync(with: [phone.published!], at: t0.addingTimeInterval(5))
        _ = try phone.sync(with: [mac.published!], at: t0.addingTimeInterval(6))
        _ = try mac.sync(with: [phone.published!], at: t0.addingTimeInterval(7))

        #expect(mac.state.notes[doc.id] == nil)
        #expect(mac.state.calendarNoteRelations.baselines[.item(target.id)] == nil)
        try WorkspaceValidator.validate(mac.state)
        try WorkspaceValidator.validate(phone.state)
    }

    @Test func followUpFieldsAndUndatedItemsSync() throws {
        let shared = emptyState()
        var mac = Device("mac", state: shared)
        var phone = Device("phone", state: shared)
        let inspiration = Inspiration.text(rawText: "手机上冒出的想法", categoryID: shared.calendar.uncategorizedID, now: t0)
        phone.state.inspirations[inspiration.id] = inspiration
        let undated = UndatedItem(title: "以后再说", categoryID: shared.calendar.uncategorizedID, createdAt: t0, updatedAt: t0)
        phone.state.undatedItems[undated.id] = undated
        var reminderItem = try item("开会", in: shared)
        reminderItem.reminder = .onStartDay(at: MinuteOfDay(hour: 9, minute: 0)!)
        phone.state.calendar.items[reminderItem.id] = reminderItem
        _ = try phone.sync(with: [], at: t0)
        _ = try mac.sync(with: [phone.published!], at: t0.addingTimeInterval(1))
        #expect(mac.state.inspirations[inspiration.id]?.rawText == "手机上冒出的想法")
        #expect(mac.state.undatedItems[undated.id]?.title == "以后再说")
        #expect(mac.state.calendar.items[reminderItem.id]?.reminder == reminderItem.reminder)
    }

    @Test func documentsRoundTripAndUnknownFormatsAreRefused() throws {
        var mac = Device("mac", state: emptyState())
        let thing = try item("一件事", in: mac.state)
        mac.state.calendar.items[thing.id] = thing
        _ = try mac.sync(with: [], at: t0)
        let encoded = try JSONEncoder().encode(mac.published!)
        let decoded = try JSONDecoder().decode(SyncDeviceDocument.self, from: encoded)
        #expect(decoded == mac.published!)

        var future = decoded
        future.deviceID = "future"
        future.format = 99
        var phone = Device("phone", state: emptyState())
        #expect(throws: WorkspaceSyncError.unsupportedFormat(99)) {
            _ = try phone.sync(with: [future], at: t0)
        }
    }

    @Test func idleSyncIsStable() throws {
        var mac = Device("mac", state: emptyState())
        let thing = try item("一件事", in: mac.state)
        mac.state.calendar.items[thing.id] = thing
        _ = try mac.sync(with: [], at: t0)
        let first = mac.published!
        let again = try mac.sync(with: [], at: t0.addingTimeInterval(60))
        #expect(!again.changedFromPeers)
        #expect(mac.published!.entries == first.entries)
    }

    @Test func randomizedEditsAlwaysConverge() throws {
        var generator = SeededGenerator(seed: 20260928)
        let shared = emptyState()
        var devices = [Device("mac", state: shared), Device("phone", state: shared)]
        var clock = t0
        for round in 0..<60 {
            let index = Int.random(in: 0...1, using: &generator)
            var device = devices[index]
            switch Int.random(in: 0...5, using: &generator) {
            case 0, 1:
                let thing = try item("事项 \(round)", in: device.state)
                device.state.calendar.items[thing.id] = thing
            case 2:
                if let id = device.state.calendar.items.keys.sorted(by: { $0.uuidString < $1.uuidString }).first {
                    device.state.calendar.items[id]?.title = "改于第 \(round) 轮"
                }
            case 3:
                if let id = device.state.calendar.items.keys.sorted(by: { $0.uuidString < $1.uuidString }).last {
                    device.state.calendar.items[id] = nil
                }
            case 4:
                device.state.revision += 1
                let doc = note("笔记 \(round)", text: "内容 \(round)", in: device.state)
                device.state.notes[doc.id] = Note(
                    id: doc.id, title: doc.title, document: doc.document, categoryID: doc.categoryID,
                    archivedAt: nil, revision: 0, createdAt: t0, updatedAt: t0
                )
            default:
                if let id = device.state.notes.keys.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }).first,
                   let existing = device.state.notes[id] {
                    device.state.notes[id] = Note(
                        id: id, title: existing.title,
                        document: BlockDocument(blocks: [.init(id: BlockID(), kind: .paragraph, inlineContent: .plain("第 \(round) 轮"), taskState: nil, indentLevel: 0)]),
                        categoryID: existing.categoryID, archivedAt: nil, revision: existing.revision,
                        createdAt: existing.createdAt, updatedAt: existing.updatedAt
                    )
                }
            }
            clock = clock.addingTimeInterval(Double(Int.random(in: 1...30, using: &generator)))
            if Bool.random(using: &generator) {
                let folder = devices.compactMap(\.published).filter { $0.deviceID != device.id }
                _ = try device.sync(with: folder, at: clock)
            }
            devices[index] = device
        }
        for _ in 0..<2 {
            for index in devices.indices {
                clock = clock.addingTimeInterval(5)
                let folder = devices.compactMap(\.published).filter { $0.deviceID != devices[index].id }
                _ = try devices[index].sync(with: folder, at: clock)
            }
        }
        #expect(try WorkspaceSyncRecords.records(of: devices[0].state) == WorkspaceSyncRecords.records(of: devices[1].state))
        try WorkspaceValidator.validate(devices[0].state)
        try WorkspaceValidator.validate(devices[1].state)
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

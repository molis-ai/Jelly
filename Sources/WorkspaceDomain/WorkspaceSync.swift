import CalendarDomain
import Foundation

// MARK: - Records

/// One independently mergeable piece of a workspace. Sync compares and
/// replaces whole records; it never merges fields inside a record.
public enum SyncRecord: Codable, Equatable, Sendable {
    case category(CalendarCategory)
    case item(CalendarItem)
    case series(WeeklySeries)
    case exception(OccurrenceKey, OccurrenceExceptionKind)
    case completion(OccurrenceCompletion)
    case note(WorkspaceNoteContent)
    case inspiration(Inspiration)
    case digest(MaterialDigest)
    case undated(UndatedItem)
    case baseline(CalendarNoteOwnerID, CalendarNoteSet)
    case occurrenceOverride(OccurrenceNoteOverride)
    case taskLink(TaskBlockCalendarLink)
    case inspirationLink(InspirationNoteLink)
}

public enum WorkspaceSyncRecords {
    static func dayKey(_ date: CalendarDate) -> String {
        String(format: "%04d-%02d-%02d", date.year, date.month, date.day)
    }

    static func key(_ occurrence: OccurrenceKey) -> String {
        "\(occurrence.seriesID.uuidString)/\(dayKey(occurrence.originalDate))"
    }

    public static func records(of state: WorkspaceState) throws -> [String: Data] {
        var result: [String: Data] = [:]
        func put(_ key: String, _ record: SyncRecord) throws {
            result[key] = try SyncCanonical.data(record)
        }
        for category in state.calendar.categories.values {
            try put("category/\(category.id.uuidString)", .category(category))
        }
        for item in state.calendar.items.values {
            try put("item/\(item.id.uuidString)", .item(item))
        }
        for series in state.calendar.recurrence.series.values {
            try put("series/\(series.id.uuidString)", .series(series))
        }
        for (occurrence, exception) in state.calendar.recurrence.exceptions {
            try put("exception/\(key(occurrence))", .exception(occurrence, exception))
        }
        for completion in state.calendar.recurrence.completions.values {
            try put("completion/\(key(completion.key))", .completion(completion))
        }
        for note in state.notes.values {
            try put("note/\(note.id.rawValue.uuidString)", .note(WorkspaceNoteContent(note: note)))
        }
        for inspiration in state.inspirations.values {
            try put("inspiration/\(inspiration.id.rawValue.uuidString)", .inspiration(inspiration))
        }
        for digest in state.materialDigests.values {
            try put("digest/\(digest.inspirationID.rawValue.uuidString)", .digest(digest))
        }
        for item in state.undatedItems.values {
            try put("undated/\(item.id.uuidString)", .undated(item))
        }
        for (owner, set) in state.calendarNoteRelations.baselines {
            let ownerKey: String
            switch owner {
            case let .item(id): ownerKey = "item/\(id.uuidString)"
            case let .series(id): ownerKey = "series/\(id.uuidString)"
            }
            try put("baseline/\(ownerKey)", .baseline(owner, set))
        }
        for override in state.calendarNoteRelations.occurrenceOverrides.values {
            try put("override/\(key(override.key))", .occurrenceOverride(override))
        }
        for link in state.taskBlockLinks {
            try put(
                "tasklink/\(link.noteID.rawValue.uuidString)/\(link.blockID.rawValue.uuidString)/\(link.calendarItemID.uuidString)",
                .taskLink(link)
            )
        }
        for link in state.inspirationNoteLinks {
            let source: UUID
            switch link.source {
            case let .live(id): source = id.rawValue
            case let .deleted(originalID, _): source = originalID.rawValue
            }
            try put("inspirationlink/\(link.noteID.rawValue.uuidString)/\(source.uuidString)", .inspirationLink(link))
        }
        return result
    }

    /// Rebuilds a workspace from record values. Note revisions come from the
    /// local state (0 for notes this device has never seen).
    public static func state(
        from records: some Sequence<Data>,
        uncategorizedID: UUID,
        localRevisions: [NoteID: Int64],
        workspaceRevision: Int64
    ) throws -> WorkspaceState {
        var categories: [UUID: CalendarCategory] = [:]
        var items: [UUID: CalendarItem] = [:]
        var series: [UUID: WeeklySeries] = [:]
        var exceptions: [OccurrenceKey: OccurrenceExceptionKind] = [:]
        var completions: [OccurrenceKey: OccurrenceCompletion] = [:]
        var notes: [NoteID: Note] = [:]
        var inspirations: [InspirationID: Inspiration] = [:]
        var digests: [InspirationID: MaterialDigest] = [:]
        var undated: [UUID: UndatedItem] = [:]
        var baselines: [CalendarNoteOwnerID: CalendarNoteSet] = [:]
        var overrides: [OccurrenceKey: OccurrenceNoteOverride] = [:]
        var taskLinks: Set<TaskBlockCalendarLink> = []
        var inspirationLinks: Set<InspirationNoteLink> = []
        let decoder = JSONDecoder.workspaceDeterministic
        for data in records {
            switch try decoder.decode(SyncRecord.self, from: data) {
            case let .category(value): categories[value.id] = value
            case let .item(value): items[value.id] = value
            case let .series(value): series[value.id] = value
            case let .exception(key, value): exceptions[key] = value
            case let .completion(value): completions[value.key] = value
            case let .note(content): notes[content.id] = content.note(revision: localRevisions[content.id] ?? 0)
            case let .inspiration(value): inspirations[value.id] = value
            case let .digest(value): digests[value.inspirationID] = value
            case let .undated(value): undated[value.id] = value
            case let .baseline(owner, set): baselines[owner] = set
            case let .occurrenceOverride(value): overrides[value.key] = value
            case let .taskLink(value): taskLinks.insert(value)
            case let .inspirationLink(value): inspirationLinks.insert(value)
            }
        }
        return WorkspaceState(
            revision: workspaceRevision,
            calendar: CalendarState(
                categories: categories,
                items: items,
                recurrence: RecurrenceGraph(series: series, exceptions: exceptions, completions: completions),
                uncategorizedID: uncategorizedID
            ),
            notes: notes,
            inspirations: inspirations,
            calendarNoteRelations: CalendarNoteRelationGraph(baselines: baselines, occurrenceOverrides: overrides),
            taskBlockLinks: taskLinks,
            inspirationNoteLinks: inspirationLinks,
            materialDigests: digests,
            undatedItems: undated
        )
    }
}

/// Canonical JSON so equal records hash equally on every device: sorted
/// object keys, millisecond dates, and set-valued arrays in sorted order.
enum SyncCanonical {
    private static let setKeys: Set<String> = [
        "weekdays", "marks", "referenceNoteIDs", "addedReferenceNoteIDs", "removedReferenceNoteIDs"
    ]

    static func data(_ record: SyncRecord) throws -> Data {
        let encoded = try JSONEncoder.workspaceDeterministic.encode(record)
        let object = try JSONSerialization.jsonObject(with: encoded)
        return try JSONSerialization.data(withJSONObject: canonicalized(object), options: [.sortedKeys])
    }

    private static func canonicalized(_ value: Any, key: String? = nil) -> Any {
        if let dictionary = value as? [String: Any] {
            return Dictionary(uniqueKeysWithValues: dictionary.map { ($0.key, canonicalized($0.value, key: $0.key)) })
        }
        guard let array = value as? [Any] else { return value }
        let values = array.map { canonicalized($0) }
        guard let key, setKeys.contains(key) else { return values }
        return values.sorted { sortKey($0) < sortKey($1) }
    }

    private static func sortKey(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func hash(_ data: Data) -> String {
        WorkspaceChecksum.sha256Hex(data)
    }
}

// MARK: - Documents

public struct SyncEntry: Codable, Equatable, Sendable {
    public var ts: Int64
    public var device: String
    /// Canonical record JSON; nil marks a deletion (tombstone).
    public var value: Data?

    public init(ts: Int64, device: String, value: Data?) {
        self.ts = ts
        self.device = device
        self.value = value
    }

    func wins(over other: SyncEntry) -> Bool {
        (ts, device) > (other.ts, other.device)
    }
}

/// What one device publishes into the shared folder. Only that device ever
/// writes its own file, so the folder never sees conflicting writers.
public struct SyncDeviceDocument: Codable, Equatable, Sendable {
    public static let currentFormat = 1

    public var format: Int
    public var deviceID: String
    public var deviceName: String
    public var uncategorizedID: UUID
    public var clock: Int64
    /// Highest timestamp of each device's edits already merged into this file.
    public var seen: [String: Int64]
    public var entries: [String: SyncEntry]
    public var publishedAt: Date

    public init(
        format: Int = SyncDeviceDocument.currentFormat,
        deviceID: String,
        deviceName: String,
        uncategorizedID: UUID,
        clock: Int64,
        seen: [String: Int64],
        entries: [String: SyncEntry],
        publishedAt: Date
    ) {
        self.format = format
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.uncategorizedID = uncategorizedID
        self.clock = clock
        self.seen = seen
        self.entries = entries
        self.publishedAt = publishedAt
    }
}

/// This device's memory of the last reconciled state (kept locally).
public struct SyncLocalMeta: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var ts: Int64
        public var device: String
        public var hash: String?
    }

    public var deviceID: String
    public var clock: Int64
    public var seen: [String: Int64]
    public var entries: [String: Entry]

    public init(deviceID: String, clock: Int64 = 0, seen: [String: Int64] = [:], entries: [String: Entry] = [:]) {
        self.deviceID = deviceID
        self.clock = clock
        self.seen = seen
        self.entries = entries
    }
}

public struct SyncReconciliation: Equatable, Sendable {
    public var state: WorkspaceState
    public var meta: SyncLocalMeta
    public var document: SyncDeviceDocument
    /// Titles of notes that were edited on two devices at once; the losing
    /// version was kept as a "（冲突副本）" note.
    public var conflictCopies: [String]
    public var changedFromPeers: Bool
}

public enum WorkspaceSyncError: Error, Equatable, Sendable {
    case unsupportedFormat(Int)
    case cannotReconcile(String)
}

// MARK: - Engine

public enum WorkspaceSyncEngine {
    public static func reconcile(
        local: WorkspaceState,
        meta existing: SyncLocalMeta?,
        peers: [SyncDeviceDocument],
        deviceID: String,
        deviceName: String,
        now: Date
    ) throws -> SyncReconciliation {
        let others = peers.filter { $0.deviceID != deviceID }
        if let bad = others.first(where: { $0.format != SyncDeviceDocument.currentFormat }) {
            throw WorkspaceSyncError.unsupportedFormat(bad.format)
        }
        let nowMS = Int64((now.timeIntervalSince1970 * 1000).rounded())
        var meta = existing ?? SyncLocalMeta(deviceID: deviceID)

        // One shared “未分类”: every device converges on the smallest id.
        let canonicalUncategorized = ([local.calendar.uncategorizedID] + others.map(\.uncategorizedID))
            .min { $0.uuidString < $1.uuidString }!
        var working = local
        if canonicalUncategorized != local.calendar.uncategorizedID {
            working = WorkspaceSyncRepair.remapUncategorized(working, to: canonicalUncategorized)
        }

        // 1. Stamp local edits made since the last reconciliation.
        let localRecords = try WorkspaceSyncRecords.records(of: working)
        stampChanges(localRecords, into: &meta, nowMS: nowMS)

        // 2. Last writer wins per record, peers in a fixed order.
        var winners: [String: SyncEntry] = Dictionary(uniqueKeysWithValues: meta.entries.map { key, entry in
            (key, SyncEntry(ts: entry.ts, device: entry.device, value: entry.hash == nil ? nil : localRecords[key]))
        })
        var lostNoteVersions: [(key: String, value: Data)] = []
        var changedFromPeers = false
        let seenBefore = meta.seen
        for peer in others.sorted(by: { $0.deviceID < $1.deviceID }) {
            for (key, entry) in peer.entries {
                guard let current = winners[key] else {
                    winners[key] = entry
                    changedFromPeers = changedFromPeers || entry.value != nil
                    continue
                }
                guard current != entry else { continue }
                let peerWins = entry.wins(over: current)
                // Neither side had seen the other's edit: a real conflict.
                // Keep whichever version loses as a copy instead of dropping it.
                if key.hasPrefix("note/"),
                   let mine = current.value,
                   let theirs = entry.value,
                   mine != theirs,
                   current.device == deviceID,
                   (peer.seen[deviceID] ?? 0) < current.ts,
                   entry.ts > (seenBefore[entry.device] ?? 0) {
                    lostNoteVersions.append((key, peerWins ? mine : theirs))
                }
                guard peerWins else { continue }
                if current.value != entry.value { changedFromPeers = true }
                winners[key] = entry
            }
            meta.seen[peer.deviceID] = max(
                meta.seen[peer.deviceID] ?? 0,
                peer.entries.values.filter { $0.device == peer.deviceID }.map(\.ts).max() ?? 0
            )
            for (device, ts) in peer.seen where device != deviceID {
                meta.seen[device] = max(meta.seen[device] ?? 0, ts)
            }
            meta.clock = max(meta.clock, peer.clock, peer.entries.values.map(\.ts).max() ?? 0)
        }

        // 3. Concurrent note edits: keep the losing local version as a copy.
        var conflictTitles: [String] = []
        for (key, value) in lostNoteVersions {
            guard case let .note(content) = try JSONDecoder.workspaceDeterministic.decode(SyncRecord.self, from: value) else { continue }
            let copyID = NoteID(deterministicUUID(from: key + SyncCanonical.hash(value)))
            var copy = content.note(revision: 0)
            copy = Note(
                id: copyID,
                title: copy.title + "（冲突副本）",
                document: copy.document,
                categoryID: copy.categoryID,
                archivedAt: copy.archivedAt,
                revision: 0,
                createdAt: copy.createdAt,
                updatedAt: copy.updatedAt
            )
            let copyKey = "note/\(copyID.rawValue.uuidString)"
            guard winners[copyKey] == nil else { continue }
            meta.clock = max(meta.clock + 1, nowMS)
            winners[copyKey] = SyncEntry(
                ts: meta.clock,
                device: deviceID,
                value: try SyncCanonical.data(.note(WorkspaceNoteContent(note: copy)))
            )
            conflictTitles.append(content.title)
        }

        // 4. Rebuild, repair cross-record references, validate.
        var merged = try WorkspaceSyncRecords.state(
            from: winners.values.compactMap(\.value),
            uncategorizedID: canonicalUncategorized,
            localRevisions: local.notes.mapValues(\.revision),
            workspaceRevision: max(local.revision, local.notes.values.map(\.revision).max() ?? 0)
        )
        merged = try WorkspaceSyncRepair.repair(merged)

        // 5. Repairs are edits too: stamp them so they travel.
        let finalRecords = try WorkspaceSyncRecords.records(of: merged)
        meta.entries = winners.mapValues { entry in
            SyncLocalMeta.Entry(ts: entry.ts, device: entry.device, hash: entry.value.map(SyncCanonical.hash))
        }
        stampChanges(finalRecords, into: &meta, nowMS: nowMS)
        meta.seen[deviceID] = meta.clock

        let published = SyncDeviceDocument(
            deviceID: deviceID,
            deviceName: deviceName,
            uncategorizedID: canonicalUncategorized,
            clock: meta.clock,
            seen: meta.seen,
            entries: Dictionary(uniqueKeysWithValues: meta.entries.map { key, entry in
                (key, SyncEntry(ts: entry.ts, device: entry.device, value: entry.hash == nil ? nil : finalRecords[key]))
            }),
            publishedAt: now
        )
        return SyncReconciliation(
            state: merged,
            meta: meta,
            document: published,
            conflictCopies: conflictTitles,
            changedFromPeers: changedFromPeers || !conflictTitles.isEmpty
        )
    }

    private static func stampChanges(_ records: [String: Data], into meta: inout SyncLocalMeta, nowMS: Int64) {
        let keys = Set(meta.entries.keys).union(records.keys).sorted()
        for key in keys {
            let hash = records[key].map(SyncCanonical.hash)
            guard meta.entries[key]?.hash != hash else { continue }
            if meta.entries[key] == nil, hash == nil { continue }
            meta.clock = max(meta.clock + 1, nowMS)
            meta.entries[key] = .init(ts: meta.clock, device: meta.deviceID, hash: hash)
        }
    }

    static func deterministicUUID(from seed: String) -> UUID {
        let hex = Array(SyncCanonical.hash(Data(seed.utf8)).prefix(32))
        var bytes = stride(from: 0, to: 32, by: 2).map { index in
            UInt8(String(hex[index..<index + 2]), radix: 16) ?? 0
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

// MARK: - Repair

/// Records merged from different devices can point at things the other
/// device deleted. Repair drops or re-points those references so the result
/// satisfies the same validator every local edit does.
public enum WorkspaceSyncRepair {
    static let uncategorizedName = "未分类"
    static let uncategorizedColor = "#8E8E93"

    public static func remapUncategorized(_ state: WorkspaceState, to newID: UUID) -> WorkspaceState {
        let oldID = state.calendar.uncategorizedID
        guard oldID != newID else { return state }
        var categories = state.calendar.categories
        let old = categories.removeValue(forKey: oldID)
        categories[newID] = CalendarCategory(
            id: newID,
            name: uncategorizedName,
            colorHex: uncategorizedColor,
            sortIndex: old?.sortIndex ?? 0,
            createdAt: old?.createdAt ?? .distantPast,
            updatedAt: old?.updatedAt ?? .distantPast
        )
        var result = state
        result.calendar = CalendarState(
            categories: categories,
            items: state.calendar.items,
            recurrence: state.calendar.recurrence,
            uncategorizedID: newID
        )
        return remapCategories(result, [oldID: newID])
    }

    static func remapCategories(_ state: WorkspaceState, _ mapping: [UUID: UUID]) -> WorkspaceState {
        guard !mapping.isEmpty else { return state }
        func map(_ id: UUID) -> UUID { mapping[id] ?? id }
        var result = state
        result.calendar.items = result.calendar.items.mapValues { item in
            var item = item
            item.categoryID = map(item.categoryID)
            return item
        }
        result.calendar.recurrence.series = result.calendar.recurrence.series.mapValues { series in
            var series = series
            series.categoryID = map(series.categoryID)
            return series
        }
        result.calendar.recurrence.exceptions = result.calendar.recurrence.exceptions.mapValues { exception in
            guard case var .modified(override) = exception else { return exception }
            override.categoryID = map(override.categoryID)
            return .modified(override)
        }
        result.notes = result.notes.mapValues { note in
            var note = note
            note.categoryID = map(note.categoryID)
            return note
        }
        result.inspirations = result.inspirations.mapValues { inspiration in
            var inspiration = inspiration
            inspiration.categoryID = map(inspiration.categoryID)
            return inspiration
        }
        result.undatedItems = result.undatedItems.mapValues { item in
            var item = item
            item.categoryID = map(item.categoryID)
            return item
        }
        return result
    }

    public static func repair(_ input: WorkspaceState) throws -> WorkspaceState {
        var state = input
        repairCategories(&state)
        repairRecurrence(&state)
        repairRelations(&state)
        repairLinks(&state)
        repairInspirationData(&state)
        do {
            try WorkspaceValidator.validate(state)
        } catch {
            throw WorkspaceSyncError.cannotReconcile(String(describing: error))
        }
        return state
    }

    private static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func repairCategories(_ state: inout WorkspaceState) {
        let uncategorizedID = state.calendar.uncategorizedID
        var categories = state.calendar.categories
        categories[uncategorizedID] = CalendarCategory(
            id: uncategorizedID,
            name: uncategorizedName,
            colorHex: uncategorizedColor,
            sortIndex: categories[uncategorizedID]?.sortIndex ?? -1,
            createdAt: categories[uncategorizedID]?.createdAt ?? .distantPast,
            updatedAt: categories[uncategorizedID]?.updatedAt ?? .distantPast
        )
        // Same name from two devices → one category (uncategorized or the
        // smallest id wins), references re-pointed.
        var mapping: [UUID: UUID] = [:]
        let groups = Dictionary(grouping: categories.values) { normalizedName($0.name) }
        for group in groups.values where group.count > 1 {
            let keeper = group.first { $0.id == uncategorizedID }
                ?? group.min { $0.id.uuidString < $1.id.uuidString }!
            for category in group where category.id != keeper.id {
                mapping[category.id] = keeper.id
                categories[category.id] = nil
            }
        }
        let ordered = categories.values.sorted { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        for (index, category) in ordered.enumerated() {
            categories[category.id]?.sortIndex = index
        }
        state.calendar = CalendarState(
            categories: categories,
            items: state.calendar.items,
            recurrence: state.calendar.recurrence,
            uncategorizedID: uncategorizedID
        )
        state = remapCategories(state, mapping)
        let known = Set(categories.keys)
        state = remapCategories(state, Dictionary(uniqueKeysWithValues: unknownCategories(in: state, known: known).map { ($0, uncategorizedID) }))
    }

    private static func unknownCategories(in state: WorkspaceState, known: Set<UUID>) -> Set<UUID> {
        var ids = Set<UUID>()
        ids.formUnion(state.calendar.items.values.map(\.categoryID))
        ids.formUnion(state.calendar.recurrence.series.values.map(\.categoryID))
        for exception in state.calendar.recurrence.exceptions.values {
            if case let .modified(override) = exception { ids.insert(override.categoryID) }
        }
        ids.formUnion(state.notes.values.map(\.categoryID))
        ids.formUnion(state.inspirations.values.map(\.categoryID))
        ids.formUnion(state.undatedItems.values.map(\.categoryID))
        return ids.subtracting(known)
    }

    private static func repairRecurrence(_ state: inout WorkspaceState) {
        let series = state.calendar.recurrence.series
        state.calendar.recurrence.exceptions = state.calendar.recurrence.exceptions.filter { series[$0.key.seriesID] != nil }
        let exceptions = state.calendar.recurrence.exceptions
        state.calendar.recurrence.completions = state.calendar.recurrence.completions.filter { key, _ in
            guard let owner = series[key.seriesID] else { return false }
            switch exceptions[key] {
            case .skipped: return false
            case .modified: return true
            case nil: return owner.weekdays.contains(key.originalDate.weekday)
            }
        }
    }

    private static func repairRelations(_ state: inout WorkspaceState) {
        let notes = Set(state.notes.keys)
        var baselines: [CalendarNoteOwnerID: CalendarNoteSet] = [:]
        for (owner, set) in state.calendarNoteRelations.baselines {
            let exists: Bool
            switch owner {
            case let .item(id): exists = state.calendar.items[id] != nil
            case let .series(id): exists = state.calendar.recurrence.series[id] != nil
            }
            guard exists else { continue }
            var cleaned = set
            if let primary = cleaned.primaryNoteID, !notes.contains(primary) { cleaned.primaryNoteID = nil }
            cleaned.referenceNoteIDs = cleaned.referenceNoteIDs.intersection(notes)
            if let primary = cleaned.primaryNoteID { cleaned.referenceNoteIDs.remove(primary) }
            guard cleaned.primaryNoteID != nil || !cleaned.referenceNoteIDs.isEmpty else { continue }
            baselines[owner] = cleaned
        }
        var overrides: [OccurrenceKey: OccurrenceNoteOverride] = [:]
        for (key, override) in state.calendarNoteRelations.occurrenceOverrides {
            guard state.calendar.recurrence.series[key.seriesID] != nil else { continue }
            var cleaned = override
            if case let .replace(noteID) = cleaned.primary, !notes.contains(noteID) { cleaned.primary = .inherit }
            cleaned.addedReferenceNoteIDs = cleaned.addedReferenceNoteIDs.intersection(notes)
            cleaned.removedReferenceNoteIDs = cleaned.removedReferenceNoteIDs.intersection(notes)
            overrides[key] = cleaned
        }
        state.calendarNoteRelations = CalendarNoteRelationGraph(baselines: baselines, occurrenceOverrides: overrides)
    }

    private static func repairLinks(_ state: inout WorkspaceState) {
        var usedBlocks = Set<BlockID>()
        var usedItems = Set<UUID>()
        var kept = Set<TaskBlockCalendarLink>()
        let ordered = state.taskBlockLinks.sorted {
            ($0.noteID.rawValue.uuidString, $0.blockID.rawValue.uuidString) < ($1.noteID.rawValue.uuidString, $1.blockID.rawValue.uuidString)
        }
        for link in ordered {
            guard let item = state.calendar.items[link.calendarItemID],
                  let note = state.notes[link.noteID],
                  let block = note.document.blocks.first(where: { $0.id == link.blockID && $0.kind == .task }),
                  state.calendarNoteRelations.baselines[.item(link.calendarItemID)]?.primaryNoteID == link.noteID,
                  item.title == TaskBlockCalendarTitle.normalized(block.inlineContent.spans.map(\.text).joined()),
                  item.completedAt == block.taskState?.completedAt,
                  !usedBlocks.contains(link.blockID),
                  !usedItems.contains(link.calendarItemID)
            else { continue }
            usedBlocks.insert(link.blockID)
            usedItems.insert(link.calendarItemID)
            kept.insert(link)
        }
        state.taskBlockLinks = kept

        state.inspirationNoteLinks = Set(state.inspirationNoteLinks.compactMap { link in
            guard state.notes[link.noteID] != nil else { return nil }
            if case let .live(id) = link.source, state.inspirations[id] == nil {
                return InspirationNoteLink(
                    source: .deleted(originalID: id, deletedAt: link.createdAt),
                    noteID: link.noteID,
                    createdAt: link.createdAt
                )
            }
            return link
        })
    }

    private static func repairInspirationData(_ state: inout WorkspaceState) {
        state.materialDigests = state.materialDigests.filter { id, digest in
            guard let inspiration = state.inspirations[id] else { return false }
            return digest.sourceChecksum == WorkspaceChecksum.inspirationSourceChecksum(inspiration)
        }
        for (id, digest) in state.materialDigests {
            if let write = digest.noteWrite, state.notes[write.noteID] == nil {
                state.materialDigests[id]?.noteWrite = nil
            }
        }
        for (id, item) in state.undatedItems {
            if let source = item.sourceInspirationID, state.inspirations[source] == nil {
                state.undatedItems[id]?.sourceInspirationID = nil
            }
        }
    }
}

import CalendarDomain
import Foundation
import WorkspaceDomain

public enum WorkspaceDocumentCodec {
    public static func encode(_ state: WorkspaceState) throws -> Data {
        do {
            try WorkspaceValidator.validate(state)
            let encoded = try JSONEncoder.workspaceDeterministic.encode(WorkspaceDocument(state: state))
            let object = try JSONSerialization.jsonObject(with: encoded)
            return try JSONSerialization.data(
                withJSONObject: canonicalized(object),
                options: [.sortedKeys]
            )
        } catch {
            throw WorkspacePersistenceError.invalidWorkspace
        }
    }

    public static func decode(_ data: Data) throws -> WorkspaceLoadResult {
        let schema: Int
        do {
            schema = try JSONDecoder.workspaceDeterministic.decode(SchemaEnvelope.self, from: data).schemaVersion
        } catch {
            throw WorkspacePersistenceError.invalidDocument
        }
        let provenance = WorkspaceLoadProvenance(
            sourceSchema: schema,
            sourceBytesSHA256: persistenceSHA256(data),
            sourceByteCount: data.count
        )
        switch schema {
        case 1, CalendarDocument.currentSchemaVersion:
            do {
                let calendar = try CalendarDocumentCodec.decode(data)
                return .init(
                    state: .empty(calendar: calendar),
                    provenance: provenance,
                    consistencyIssues: []
                )
            } catch let error as BackupError {
                switch error {
                case let .unsupportedSchema(value): throw WorkspacePersistenceError.unsupportedSchema(value)
                default: throw WorkspacePersistenceError.invalidDocument
                }
            } catch {
                throw WorkspacePersistenceError.invalidDocument
            }
        case 3:
            return try loadAndInspect(migrateV3TaskTitles(try decodeWorkspace(data)), provenance)
        case 4:
            return try loadAndInspect(try migrateWorkspaceV4(data), provenance)
        case WorkspaceDocument.currentSchemaVersion:
            return try loadAndInspect(try decodeWorkspace(data), provenance)
        default:
            throw WorkspacePersistenceError.unsupportedSchema(schema)
        }
    }

    private static func loadAndInspect(
        _ state: WorkspaceState,
        _ provenance: WorkspaceLoadProvenance
    ) throws -> WorkspaceLoadResult {
        let report = WorkspaceConsistencyInspector.inspect(state)
        guard !report.hasFatalIssues else { throw WorkspacePersistenceError.invalidDocument }
        return .init(state: state, provenance: provenance, consistencyIssues: report.issues)
    }

    private static func migrateWorkspaceV4(_ data: Data) throws -> WorkspaceState {
        do {
            return try JSONDecoder.workspaceDeterministic
                .decode(WorkspaceDocumentV4.self, from: data)
                .state
                .migrated()
        } catch let error as WorkspacePersistenceError {
            throw error
        } catch {
            throw WorkspacePersistenceError.invalidDocument
        }
    }

    private static func decodeWorkspace(_ data: Data) throws -> WorkspaceState {
        do {
            return try JSONDecoder.workspaceDeterministic.decode(WorkspaceDocument.self, from: data).state
        } catch {
            throw WorkspacePersistenceError.invalidDocument
        }
    }

    private static func migrateV3TaskTitles(_ source: WorkspaceState) -> WorkspaceState {
        var migrated = source
        for link in source.taskBlockLinks {
            guard let block = source.notes[link.noteID]?.document.blocks.first(where: {
                $0.id == link.blockID && $0.kind == .task
            }), migrated.calendar.items[link.calendarItemID] != nil else { continue }
            migrated.calendar.items[link.calendarItemID]?.title =
                block.inlineContent.spans.map(\.text).joined()
        }
        return migrated
    }

    private struct SchemaEnvelope: Decodable {
        let schemaVersion: Int
    }

    private struct WorkspaceDocumentV4: Decodable {
        var state: WorkspaceStateV4
    }

    private struct WorkspaceStateV4: Decodable {
        var revision: Int64
        var calendar: CalendarState
        var notes: [NoteID: Note]
        var inspirations: [InspirationID: Inspiration]
        var calendarNoteRelations: CalendarNoteRelationGraph
        var taskBlockLinks: Set<TaskBlockCalendarLink>
        var inspirationNoteLinks: Set<InspirationNoteLink>
        var materialDigests: [InspirationID: LegacyMaterialDigestV4]

        enum CodingKeys: String, CodingKey {
            case revision
            case calendar
            case notes
            case inspirations
            case calendarNoteRelations
            case taskBlockLinks
            case inspirationNoteLinks
            case materialDigests
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            revision = try container.decode(Int64.self, forKey: .revision)
            calendar = try container.decode(CalendarState.self, forKey: .calendar)
            notes = try container.decode([NoteID: Note].self, forKey: .notes)
            inspirations = try container.decode([InspirationID: Inspiration].self, forKey: .inspirations)
            calendarNoteRelations = try container.decode(
                CalendarNoteRelationGraph.self,
                forKey: .calendarNoteRelations
            )
            taskBlockLinks = try container.decode(Set<TaskBlockCalendarLink>.self, forKey: .taskBlockLinks)
            inspirationNoteLinks = try container.decode(
                Set<InspirationNoteLink>.self,
                forKey: .inspirationNoteLinks
            )
            materialDigests = try container.decodeIfPresent(
                [InspirationID: LegacyMaterialDigestV4].self,
                forKey: .materialDigests
            ) ?? [:]
        }

        func migrated() throws -> WorkspaceState {
            var digests: [InspirationID: MaterialDigest] = [:]
            for (key, legacy) in materialDigests {
                digests[key] = try legacy.migrated()
            }
            return WorkspaceState(
                revision: revision,
                calendar: calendar,
                notes: notes,
                inspirations: inspirations,
                calendarNoteRelations: calendarNoteRelations,
                taskBlockLinks: taskBlockLinks,
                inspirationNoteLinks: inspirationNoteLinks,
                materialDigests: digests
            )
        }
    }

    private static func canonicalized(_ value: Any, key: String? = nil) -> Any {
        if let dictionary = value as? [String: Any] {
            return Dictionary(uniqueKeysWithValues: dictionary.map { childKey, childValue in
                (childKey, canonicalized(childValue, key: childKey))
            })
        }
        guard let array = value as? [Any] else { return value }
        let values = array.map { canonicalized($0) }
        guard let key else { return values }
        if key == "weekdays"
            || [
                "taskBlockLinks", "inspirationNoteLinks", "referenceNoteIDs", "marks",
                "addedReferenceNoteIDs", "removedReferenceNoteIDs"
            ].contains(key) {
            return values.sorted { sortKey(for: $0) < sortKey(for: $1) }
        }
        guard [
            "categories", "items", "series", "exceptions", "completions", "notes",
            "inspirations", "baselines", "occurrenceOverrides", "materialDigests"
        ].contains(key), values.count.isMultiple(of: 2)
        else { return values }
        return stride(from: 0, to: values.count, by: 2)
            .map { [values[$0], values[$0 + 1]] }
            .sorted { sortKey(for: $0[0]) < sortKey(for: $1[0]) }
            .flatMap { $0 }
    }

    private static func sortKey(for value: Any) -> String {
        guard JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys])
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func canonicalPersistentData<Value: Encodable>(_ value: Value) throws -> Data {
        let encoded = try JSONEncoder.workspaceDeterministic.encode(value)
        let object = try JSONSerialization.jsonObject(with: encoded)
        return try JSONSerialization.data(withJSONObject: canonicalized(object), options: [.sortedKeys])
    }
}

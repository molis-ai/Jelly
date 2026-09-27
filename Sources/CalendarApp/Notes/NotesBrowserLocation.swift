import CalendarDomain
import Foundation
import WorkspaceDomain

enum NotesBrowserLocation: Hashable {
    case all
    case category(UUID)
    case archived

    func newNoteCategoryID(fallback: UUID) -> UUID {
        if case let .category(categoryID) = self { return categoryID }
        return fallback
    }

    func title(in categories: [CalendarCategory]) -> String {
        switch self {
        case .all: "全部笔记"
        case let .category(categoryID):
            categories.first(where: { $0.id == categoryID })?.name ?? "分类"
        case .archived: "归档"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .all: "notes-folder-all"
        case let .category(categoryID): "notes-folder-category-\(categoryID.uuidString)"
        case .archived: "notes-folder-archived"
        }
    }

    func aligned(with note: Note) -> NotesBrowserLocation {
        if note.archivedAt != nil { return .archived }
        switch self {
        case .all:
            return .all
        case let .category(categoryID) where categoryID == note.categoryID:
            return self
        case .category, .archived:
            return .category(note.categoryID)
        }
    }

    func contains(_ note: Note) -> Bool {
        switch self {
        case .all:
            note.archivedAt == nil
        case let .category(categoryID):
            note.archivedAt == nil && note.categoryID == categoryID
        case .archived:
            note.archivedAt != nil
        }
    }
}

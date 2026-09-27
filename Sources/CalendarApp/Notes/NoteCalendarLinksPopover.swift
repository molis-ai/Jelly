import CalendarDomain
import SwiftUI
import WorkspaceDomain

/// Notes-side surface listing every calendar arrangement that uses this note.
struct NoteCalendarLinksPopover: View {
    let store: WorkspaceStore
    let noteID: NoteID
    var onOpenTarget: (WorkspaceDeepLinkTarget) -> Void = { _ in }

    private var arrangements: [NoteCalendarArrangement] {
        NoteCalendarArrangementProjection.make(noteID: noteID, state: store.state)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("这篇笔记的日历安排")
                .font(.headline)
            if arrangements.isEmpty {
                Text("这篇笔记还没有安排到日历。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(arrangements) { arrangement in
                    Button {
                        onOpenTarget(arrangement.target)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: arrangement.isCompleted ? "checkmark.circle.fill" : "circle")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(arrangement.title).lineLimit(1)
                                Text(arrangement.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(minWidth: 240)
    }
}

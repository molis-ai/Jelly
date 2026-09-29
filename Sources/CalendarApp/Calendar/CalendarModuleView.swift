import SwiftUI

struct CalendarModuleView: View {
    let store: WorkspaceStore
    @ObservedObject var newItemRouter: WorkspaceNewItemRouter
    @ObservedObject var deepLinkRouter: WorkspaceDeepLinkRouter
    @ObservedObject var transitionCoordinator: WorkspaceRouteTransitionCoordinator
    @AppStorage("calendar.undatedPanelVisible") private var undatedPanelVisible = false
    @State private var undatedModel: UndatedListModel?

    var body: some View {
        HStack(spacing: 0) {
            monthView
            if undatedPanelVisible, let undatedModel {
                UndatedListPanel(
                    model: undatedModel,
                    categories: store.calendarState.categories,
                    onClose: { undatedPanelVisible = false }
                )
                .transition(.move(edge: .trailing))
            }
        }
        .onAppear {
            if undatedModel == nil { undatedModel = UndatedListModel(store: store) }
        }
    }

    private var monthView: some View {
        MonthView(
            store: store,
            newItemRequest: newItemRouter.pendingRequest,
            consumeNewItemRequest: { requestID, route in
                newItemRouter.consume(requestID, route: route)
            },
            deepLinkRequest: deepLinkRouter.pendingRequest,
            consumeDeepLinkRequest: { requestID, target in
                deepLinkRouter.consume(requestID, target: target)
            },
            onOpenNote: { noteID in
                Task { @MainActor in
                    guard await transitionCoordinator.requestActivation(.notes) else { return }
                    _ = deepLinkRouter.request(.note(noteID))
                }
            },
            undatedCount: store.state.undatedItems.count,
            onToggleUndated: { undatedPanelVisible.toggle() }
        )
        .frame(
            minWidth: WorkspaceWindowLayout.calendarContentMinimumWidth,
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }
}

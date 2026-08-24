import Combine
import SwiftUI
import WorkspaceDomain

@MainActor
final class WorkspaceModuleHost: @MainActor Identifiable {
    let route: WorkspaceRoute
    let content: AnyView
    let lifetimeToken: AnyObject

    var id: WorkspaceRoute { route }

    init(route: WorkspaceRoute, content: AnyView, lifetimeToken: AnyObject) {
        self.route = route
        self.content = content
        self.lifetimeToken = lifetimeToken
    }
}

enum WorkspaceModuleHostPresentation: Equatable {
    case active
    case inactive

    var allowsHitTesting: Bool {
        self == .active
    }

    var accessibilityHidden: Bool {
        self == .inactive
    }
}

/// Builds every enabled module exactly once. AppShell keeps this store alive so
/// switching routes only changes presentation and never resets module state.
@MainActor
final class WorkspaceModuleHostStore: ObservableObject {
    private let hostsByRoute: [WorkspaceRoute: WorkspaceModuleHost]
    let hosts: [WorkspaceModuleHost]

    init(
        features: WorkspaceFeatures,
        build: (WorkspaceRoute) -> WorkspaceModuleHost
    ) {
        let builtHosts = WorkspaceRoute.visibleRoutes(features).map(build)
        hosts = builtHosts
        hostsByRoute = Dictionary(uniqueKeysWithValues: builtHosts.map { ($0.route, $0) })
    }

    func host(for route: WorkspaceRoute) -> WorkspaceModuleHost? {
        hostsByRoute[route]
    }

    func presentation(
        for route: WorkspaceRoute,
        activeRoute: WorkspaceRoute
    ) -> WorkspaceModuleHostPresentation {
        route == activeRoute ? .active : .inactive
    }
}

private final class WorkspaceModuleLifetimeToken {}

struct WorkspaceCreationNotice: Identifiable, Equatable {
    let id = UUID()
    let stateGeneration: UInt
    let undoLabel: String

    static func resolve(stateGeneration: UInt, undoLabel: String?) -> Self? {
        guard WorkspaceCreationFeedback.isCreationUndoLabel(undoLabel), let undoLabel else {
            return nil
        }
        return Self(stateGeneration: stateGeneration, undoLabel: undoLabel)
    }
}

struct AppShellView: View {
    let store: WorkspaceStore
    let features: WorkspaceFeatures
    let focusRegistry: EditorFocusRegistry
    let searchIndex: WorkspaceSearchIndex
    let terminationCoordinator: NotesApplicationTerminationCoordinator?
    @ObservedObject var routeState: WorkspaceRouteState
    @ObservedObject var newItemRouter: WorkspaceNewItemRouter
    @ObservedObject var deepLinkRouter: WorkspaceDeepLinkRouter
    @ObservedObject var searchRouter: WorkspaceSearchRouter
    @ObservedObject var transitionCoordinator: WorkspaceRouteTransitionCoordinator
    @StateObject private var moduleHosts: WorkspaceModuleHostStore
    @State private var creationNotice: WorkspaceCreationNotice?

    init(
        store: WorkspaceStore,
        features: WorkspaceFeatures,
        routeState: WorkspaceRouteState,
        newItemRouter: WorkspaceNewItemRouter,
        deepLinkRouter: WorkspaceDeepLinkRouter = WorkspaceDeepLinkRouter(),
        searchRouter: WorkspaceSearchRouter = WorkspaceSearchRouter(),
        searchIndex: WorkspaceSearchIndex = WorkspaceSearchIndex(),
        focusRegistry: EditorFocusRegistry = EditorFocusRegistry(),
        transitionCoordinator: WorkspaceRouteTransitionCoordinator? = nil,
        terminationCoordinator: NotesApplicationTerminationCoordinator? = nil,
        materialDigestOperator: (any MaterialDigestOperating)? = nil,
        isDigestConfigured: @escaping @MainActor () -> Bool = { true },
        moduleHostBuilder: ((WorkspaceRoute) -> WorkspaceModuleHost)? = nil
    ) {
        self.store = store
        self.features = features
        self.focusRegistry = focusRegistry
        self.searchIndex = searchIndex
        self.terminationCoordinator = terminationCoordinator
        self.routeState = routeState
        self.newItemRouter = newItemRouter
        self.deepLinkRouter = deepLinkRouter
        self.searchRouter = searchRouter
        let coordinator = transitionCoordinator
            ?? WorkspaceRouteTransitionCoordinator(routeState: routeState, features: features)
        self.transitionCoordinator = coordinator

        let builder = moduleHostBuilder ?? { route in
            switch route {
            case .calendar:
                WorkspaceModuleHost(
                    route: .calendar,
                    content: AnyView(CalendarModuleView(
                        store: store,
                        newItemRouter: newItemRouter,
                        deepLinkRouter: deepLinkRouter,
                        transitionCoordinator: coordinator
                    )),
                    lifetimeToken: WorkspaceModuleLifetimeToken()
                )
            case .notes:
                WorkspaceModuleHost(
                    route: .notes,
                    content: AnyView(NotesSplitView(
                        store: store,
                        focusRegistry: focusRegistry,
                        transitionCoordinator: coordinator,
                        deepLinkRouter: deepLinkRouter,
                        newItemRouter: newItemRouter,
                        searchIndex: searchIndex,
                        terminationCoordinator: terminationCoordinator
                    )),
                    lifetimeToken: WorkspaceModuleLifetimeToken()
                )
            case .inspiration:
                WorkspaceModuleHost(
                    route: .inspiration,
                    content: AnyView(InspirationSplitView(
                        store: store,
                        newItemRouter: newItemRouter,
                        transitionCoordinator: coordinator,
                        deepLinkRouter: deepLinkRouter,
                        searchIndex: searchIndex,
                        digestOperator: materialDigestOperator,
                        isDigestConfigured: isDigestConfigured
                    )),
                    lifetimeToken: WorkspaceModuleLifetimeToken()
                )
            }
        }
        _moduleHosts = StateObject(wrappedValue: WorkspaceModuleHostStore(
            features: features,
            build: builder
        ))
    }

    var body: some View {
        let stateGeneration = store.statePublicationGeneration
        HStack(spacing: 0) {
            WorkspaceNavigationRail(
                store: store,
                features: features,
                routeState: routeState,
                transitionCoordinator: transitionCoordinator
            )
            ZStack {
                ForEach(moduleHosts.hosts) { host in
                    let presentation = moduleHosts.presentation(
                        for: host.route,
                        activeRoute: routeState.route
                    )
                    host.content
                        .environment(\.workspaceActiveRoute, routeState.route)
                        .opacity(presentation == .active ? 1 : 0)
                        .allowsHitTesting(presentation.allowsHitTesting)
                        .accessibilityHidden(presentation.accessibilityHidden)
                        .accessibilityIdentifier("workspace-module-\(host.route.rawValue)")
                }
            }
            .frame(
                minWidth: WorkspaceWindowLayout.calendarContentMinimumWidth,
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topLeading
            )
        }
        .frame(
            minWidth: WorkspaceWindowLayout.minimumWidth,
            minHeight: WorkspaceWindowLayout.minimumHeight,
            alignment: .topLeading
        )
        .sheet(isPresented: $searchRouter.isPresented) {
            WorkspaceGlobalSearchView(
                store: store,
                searchIndex: searchIndex,
                onOpen: openSearchResult,
                router: searchRouter
            )
        }
        .overlay(alignment: .bottom) {
            if let creationNotice {
                WorkspaceCreationToast(
                    message: creationNotice.undoLabel,
                    onUndo: { undoCreation(creationNotice) }
                )
                .padding(.bottom, 16)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .onChange(of: stateGeneration, initial: true) { _, newGeneration in
            withAnimation(.easeOut(duration: 0.16)) {
                creationNotice = WorkspaceCreationNotice.resolve(
                    stateGeneration: newGeneration,
                    undoLabel: store.latestUndoLabel
                )
            }
        }
        .task(id: creationNotice?.id) {
            guard let notice = creationNotice else { return }
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, creationNotice == notice else { return }
            withAnimation(.easeOut(duration: 0.16)) {
                creationNotice = nil
            }
        }
    }

    private func undoCreation(_ notice: WorkspaceCreationNotice) {
        guard creationNotice == notice,
              store.statePublicationGeneration == notice.stateGeneration,
              store.latestUndoLabel == notice.undoLabel,
              store.canUndo
        else {
            creationNotice = nil
            return
        }
        Task { @MainActor in
            _ = try? await store.undo()
            if creationNotice == notice { creationNotice = nil }
        }
    }

    private func openSearchResult(_ objectID: WorkspaceObjectID) {
        let target: WorkspaceDeepLinkTarget
        switch objectID {
        case let .calendarItem(id): target = .calendarItem(id)
        case let .note(id): target = .note(id)
        case let .inspiration(id): target = .inspiration(id)
        }
        Task {
            guard await transitionCoordinator.requestActivation(target.route) else { return }
            deepLinkRouter.request(target)
        }
    }
}

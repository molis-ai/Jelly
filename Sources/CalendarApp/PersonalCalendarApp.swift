import SwiftUI

enum CalendarAppWindow {
    case mainCalendar
    case categoryManager
    case recoveryCenter
}

enum CalendarAppWindowID {
    static let recoveryCenter = "recovery-center"
}

enum CalendarAppCommandPolicy {
    static func installsBackupCommands(in window: CalendarAppWindow) -> Bool {
        window == .mainCalendar
    }
}

@MainActor
@main
struct PersonalCalendarApp: App {
    @NSApplicationDelegateAdaptor(NotesApplicationTerminationCoordinator.self)
    private var terminationCoordinator
    @State private var environment: AppEnvironment?
    @State private var startupError: String?
    @StateObject private var routeState: WorkspaceRouteState
    @StateObject private var newItemRouter: WorkspaceNewItemRouter
    @StateObject private var deepLinkRouter: WorkspaceDeepLinkRouter
    @StateObject private var editorFocusRegistry: EditorFocusRegistry
    @StateObject private var transitionCoordinator: WorkspaceRouteTransitionCoordinator
    @StateObject private var searchRouter: WorkspaceSearchRouter
    @AppStorage(CalendarAppearancePreference.storageKey)
    private var appearancePreferenceRaw = CalendarAppearancePreference.light.rawValue

    init() {
        let launch = AppEnvironment.loadLive()
        let initialEnvironment = try? launch.get()
        _environment = State(initialValue: initialEnvironment)
        _startupError = State(initialValue: launch.failureDescription)
        let features = initialEnvironment?.features ?? .production
        let routeState = WorkspaceRouteState(features: features)
        _routeState = StateObject(wrappedValue: routeState)
        _newItemRouter = StateObject(wrappedValue: WorkspaceNewItemRouter())
        _deepLinkRouter = StateObject(wrappedValue: WorkspaceDeepLinkRouter())
        _editorFocusRegistry = StateObject(wrappedValue: EditorFocusRegistry())
        _transitionCoordinator = StateObject(wrappedValue: WorkspaceRouteTransitionCoordinator(
            routeState: routeState,
            features: features
        ))
        _searchRouter = StateObject(wrappedValue: WorkspaceSearchRouter())
    }

    private var appearancePreference: CalendarAppearancePreference {
        CalendarAppearancePreference(rawValue: appearancePreferenceRaw) ?? .light
    }

    var body: some Scene {
        Window("Jelly", id: "main-calendar") {
            Group {
                if let environment {
                    AppShellView(
                        store: environment.store,
                        features: environment.features,
                        routeState: routeState,
                        newItemRouter: newItemRouter,
                        deepLinkRouter: deepLinkRouter,
                        searchRouter: searchRouter,
                        searchIndex: environment.searchIndex,
                        focusRegistry: editorFocusRegistry,
                        transitionCoordinator: transitionCoordinator,
                        terminationCoordinator: terminationCoordinator,
                        materialDigestOperator: environment.materialDigestOperator,
                        isDigestConfigured: {
                            DigestRuntimeConfiguration.isConfigured(
                                endpoint: environment.digestSettingsStore.endpoint,
                                model: environment.digestSettingsStore.model,
                                secret: try? environment.digestCredentialStore.load()
                            )
                        }
                    )
                    .task {
                        await environment.store.load()
                        await environment.materialDigestOperator?.reconcileInterruptedRuns()
                    }
                } else {
                    AppStartupFailureView(
                        message: startupError ?? "无法打开数据目录。",
                        onRetry: retryStartup
                    )
                }
            }
                .preferredColorScheme(appearancePreference.preferredColorScheme)
                .onAppear { CalendarAppearancePreference.applyToApplication(appearancePreference) }
                .onChange(of: appearancePreferenceRaw) { _, newValue in
                    let preference = CalendarAppearancePreference(rawValue: newValue) ?? .light
                    CalendarAppearancePreference.applyToApplication(preference)
                }
        }
        .defaultSize(width: 1180, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            if let environment {
                WorkspaceCommands(
                    routeState: routeState,
                    newItemRouter: newItemRouter,
                    transitionCoordinator: transitionCoordinator,
                    searchRouter: searchRouter,
                    features: environment.features
                )
                CalendarUndoCommands(store: environment.store, focusRegistry: editorFocusRegistry)
                if CalendarAppCommandPolicy.installsBackupCommands(in: .mainCalendar) {
                    BackupCommands(store: environment.store, rollbackDirectory: environment.dataURLs.rollbackDirectory)
                }
            }
        }

        Window("恢复与备份", id: CalendarAppWindowID.recoveryCenter) {
            Group {
                if let environment {
                    RecoveryCenterView(store: environment.store)
                } else {
                    AppStartupFailureView(
                        message: startupError ?? "无法打开数据目录。",
                        onRetry: retryStartup
                    )
                }
            }
                .preferredColorScheme(appearancePreference.preferredColorScheme)
        }
        .defaultSize(width: 560, height: 440)

        Settings {
            if let environment {
                DigestSettingsView(
                    settings: environment.digestSettingsStore,
                    credentials: environment.digestCredentialStore
                )
            } else {
                Text("无法打开材料提炼设置。")
                    .frame(minWidth: 360, minHeight: 180)
            }
        }

        // Category manager is presented as a sheet on the main calendar window so it
        // always appears on the same display (separate Window scenes often restore to
        // another monitor on multi-display Macs).
    }

    private func retryStartup() {
        let launch = AppEnvironment.loadLive()
        switch launch {
        case let .success(environment):
            self.environment = environment
            startupError = nil
        case let .failure(error):
            environment = nil
            startupError = "无法创建或打开 Jelly 数据目录：\(error.localizedDescription)"
        }
    }
}

private extension Result where Failure == Error {
    var failureDescription: String? {
        guard case let .failure(error) = self else { return nil }
        return "无法创建或打开 Jelly 数据目录：\(error.localizedDescription)"
    }
}

private struct AppStartupFailureView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Jelly 无法启动", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("重试", action: onRetry)
                .accessibilityLabel("重试打开 Jelly 数据目录")
        }
        .frame(minWidth: 520, minHeight: 360)
    }
}

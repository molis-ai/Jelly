import SwiftUI
import CalendarDomain
import WorkspaceDomain

@main
struct JellyIOSApp: App {
    @State private var workspace: MobileWorkspace?
    @State private var startupError: String?
    @AppStorage("jelly.ios.appearance") private var appearance = "system"

    var body: some Scene {
        WindowGroup {
            Group {
                if let workspace {
                    MobileRootView(workspace: workspace)
                } else if let startupError {
                    ContentUnavailableView("无法打开 Jelly", systemImage: "externaldrive.badge.exclamationmark",
                                           description: Text(startupError))
                } else {
                    ProgressView("正在打开 Jelly…")
                }
            }
            .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
            .task {
                guard workspace == nil, startupError == nil else { return }
                do {
                    let value = try MobileWorkspace()
                    workspace = value
                    await value.load()
                } catch {
                    startupError = "本地工作空间暂时无法读取。\(error.localizedDescription)"
                }
            }
        }
    }
}

struct MobileRootView: View {
    @Bindable var workspace: MobileWorkspace
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    @State private var changingTab = false
    @State private var showingSettings = false
    @State private var showingSearch = false
    @State private var reminders = MobileReminderScheduler()

    var body: some View {
        TabView(selection: Binding(get: { selectedTab }, set: { next in
            guard !changingTab, next != selectedTab else { return }
            changingTab = true
            Task {
                defer { changingTab = false }
                if await workspace.flushEditors() { selectedTab = next }
            }
        })) {
            NavigationStack {
                MobileCalendarView(workspace: workspace)
                    .toolbar { globalTools }
            }
            .tabItem { Label("日历", systemImage: "calendar") }.tag(0)
            NavigationStack {
                MobileNotesView(workspace: workspace)
                    .toolbar { globalTools }
            }
            .tabItem { Label("笔记", systemImage: "doc.text") }.tag(1)
            NavigationStack {
                MobileInspirationView(workspace: workspace)
                    .toolbar { globalTools }
            }
            .tabItem { Label("灵感", systemImage: "lightbulb") }.tag(2)
        }
        .tint(CalendarTheme.appearance(for: colorScheme).controlAccent)
        .onChange(of: workspace.store.statePublicationGeneration) { _, _ in
            guard workspace.isReady else { return }
            Task { await reminders.sync(state: workspace.state) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, workspace.isReady {
                Task { await reminders.sync(state: workspace.state) }
            }
            if phase == .active, workspace.isReady { workspace.mcp.startIfNeeded() }
            else if phase == .background {
                workspace.mcp.stop()
                Task { await workspace.flushEditors() }
            }
        }
        .onChange(of: workspace.isReady) { _, ready in
            if ready, scenePhase == .active { workspace.mcp.startIfNeeded() }
        }
        .sheet(isPresented: $showingSettings) { MobileSettingsView(workspace: workspace) }
        .sheet(isPresented: $showingSearch) { MobileSearchView(workspace: workspace) }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !workspace.isReady {
                MobileRecoveryBanner(workspace: workspace)
            }
        }
        .alert("操作未完成", isPresented: Binding(get: { workspace.errorMessage != nil }, set: { if !$0 { workspace.errorMessage = nil } })) {
            Button("知道了") { workspace.errorMessage = nil }
        } message: { Text(workspace.errorMessage ?? "") }
    }

    @ToolbarContentBuilder private var globalTools: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("搜索", systemImage: "magnifyingglass") {
                Task { if await workspace.flushEditors() { showingSearch = true } }
            }
                .accessibilityIdentifier("global-search")
            Menu {
                Button("撤销", systemImage: "arrow.uturn.backward") { Task { await workspace.undo() } }
                    .disabled(!workspace.store.canUndo)
                Button("重做", systemImage: "arrow.uturn.forward") { Task { await workspace.redo() } }
                    .disabled(!workspace.store.canRedo)
                Divider()
                Button("设置", systemImage: "gearshape") {
                    Task { if await workspace.flushEditors() { showingSettings = true } }
                }
            } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
            .accessibilityLabel("更多操作")
        }
    }
}

struct MobileSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(CalendarTheme.appearance(for: colorScheme).canvas)
            .foregroundStyle(CalendarTheme.appearance(for: colorScheme).primaryText)
    }
}

extension View {
    func jellySurface() -> some View { modifier(MobileSurface()) }
}

struct MobileEmptyState: View {
    let title: String
    let symbol: String
    let message: String
    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(message))
            .padding(.vertical, 24)
    }
}

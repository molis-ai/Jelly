import AppIntents
import CalendarDomain
import Foundation
import UniformTypeIdentifiers
import WorkspaceDomain

/// "嘿 Siri，用 Jelly 记灵感" or a share-sheet Shortcut: the text is stored
/// exactly as given, without opening the app.
struct CaptureInspirationIntent: AppIntent {
    static let title: LocalizedStringResource = "收进 Jelly 灵感"
    static let description = IntentDescription(
        "把一段文字或一个链接原样收进 Jelly 的灵感。可以在快捷指令里放进分享表单，或让 Siri 听写。"
    )
    static let openAppWhenRun = false

    @Parameter(title: "内容", requestValueDialog: IntentDialog("要记下什么？"))
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("把 \(\.$text) 收进 Jelly 灵感")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let workspace = try await MobileWorkspace.loadedShared()
        guard workspace.isReady else { throw JellyIntentError.workspaceUnavailable }
        let service = InspirationCaptureService(store: workspace.store, followUp: workspace.ai.followUp)
        do {
            _ = try await service.capture(text, origin: .shortcut)
        } catch InspirationCaptureError.empty {
            throw JellyIntentError.empty
        }
        return .result(dialog: IntentDialog("已收进灵感"))
    }
}

/// Screenshots, PDFs and recordings shared from other apps become material
/// inspirations, copied into Jelly's own container first.
struct CaptureMaterialIntent: AppIntent {
    static let title: LocalizedStringResource = "把文件收进 Jelly"
    static let description = IntentDescription("截图、图片、PDF、音频或视频作为材料收进 Jelly 灵感，之后可以提炼。")
    static let openAppWhenRun = false

    // `supportedContentTypes:` needs iOS 18; identifiers work from iOS 16.
    @Parameter(
        title: "文件",
        supportedTypeIdentifiers: ["public.image", "com.adobe.pdf", "public.audio", "public.movie", "public.plain-text", "public.html"]
    )
    var file: IntentFile

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let workspace = try await MobileWorkspace.loadedShared()
        guard workspace.isReady else { throw JellyIntentError.workspaceUnavailable }
        let kind = try MobileMaterialImport.kind(for: file.type, filename: file.filename)
        let reference = try MobileMaterialImport.store(
            data: file.data,
            filename: file.filename.isEmpty ? "材料" : file.filename,
            under: workspace.rootURL
        )
        let now = Date()
        let inspiration = Inspiration(
            id: InspirationID(),
            inputKind: .file,
            rawText: nil,
            rawURL: nil,
            rawFile: reference,
            resolvedSourceKind: kind,
            resolvedMetadata: nil,
            categoryID: workspace.store.calendarState.uncategorizedID,
            lifecycle: .active,
            createdAt: now,
            updatedAt: now
        )
        let outcome = try await workspace.store.sendWorkspace(
            .createInspiration(.init(inspiration: inspiration)),
            undoLabel: WorkspaceCreationFeedback.inspiration(text: reference.displayName, categoryName: "未分类")
        )
        guard case .committed = outcome else { throw JellyIntentError.workspaceUnavailable }
        return .result(dialog: IntentDialog("已收进灵感：\(reference.displayName)"))
    }
}

enum MobileMaterialImport {
    static func kind(for type: UTType?, filename: String) throws -> ResolvedSourceKind {
        let resolved = type ?? UTType(filenameExtension: (filename as NSString).pathExtension)
        if resolved?.conforms(to: .image) == true { return .image }
        if resolved?.conforms(to: .pdf) == true { return .document }
        if resolved?.conforms(to: .audio) == true { return .audio }
        if resolved?.conforms(to: .movie) == true { return .video }
        if resolved?.conforms(to: .html) == true { return .article }
        if resolved?.conforms(to: .plainText) == true { return .plainText }
        throw JellyIntentError.unsupportedFile
    }

    static func store(data: Data, filename: String, under root: URL) throws -> FileReference {
        let directory = root
            .appendingPathComponent("Materials", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = filename.replacingOccurrences(of: "/", with: "-")
        let destination = directory.appendingPathComponent(safeName)
        try data.write(to: destination, options: .atomic)
        let bookmark = try destination.bookmarkData(
            options: [.minimalBookmark],
            includingResourceValuesForKeys: [.contentTypeKey, .fileSizeKey],
            relativeTo: nil
        )
        return FileReference(bookmarkData: bookmark, displayName: safeName)
    }
}

enum JellyIntentError: Error, CustomLocalizedStringResourceConvertible {
    case empty
    case unsupportedFile
    case workspaceUnavailable

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .empty: "没有可以收下的内容。"
        case .unsupportedFile: "这类文件还不能作为材料收下。"
        case .workspaceUnavailable: "Jelly 的数据暂时打不开，请打开 App 查看。"
        }
    }
}

struct JellyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureInspirationIntent(),
            phrases: [
                "用 \(.applicationName) 记灵感",
                "在 \(.applicationName) 里记一条",
                "Capture in \(.applicationName)"
            ],
            shortTitle: "记灵感",
            systemImageName: "lightbulb"
        )
        AppShortcut(
            intent: CaptureMaterialIntent(),
            phrases: ["把文件收进 \(.applicationName)"],
            shortTitle: "收进材料",
            systemImageName: "doc.badge.plus"
        )
    }
}

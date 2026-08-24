import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("MaterialSourceResolverTests")
struct MaterialSourceResolverTests {
    @Test func resolverUsesPlatformIdentityInsteadOfDisplayVideoKind() throws {
        let bilibili = try #require(MaterialSourceResolver.resolve(.url(
            "https://www.bilibili.com/video/BV1xx411c7mD/", kind: .video
        )))
        let foreignVideo = try #require(MaterialSourceResolver.resolve(.url(
            "https://example.com/video/1", kind: .video
        )))
        #expect(bilibili.descriptor.kind == .bilibiliVideo)
        #expect(foreignVideo.descriptor.kind == .publicWebArticle)
    }

    @Test func resolverPreservesDirectTextAndFileIdentity() throws {
        let text = Inspiration.text(
            rawText: "第一段\n\n第二段",
            categoryID: UUID(),
            now: .distantPast
        )
        let textSource = try #require(MaterialSourceResolver.resolve(text))
        #expect(textSource.descriptor.kind == .localText)
        #expect(textSource.text == text.rawText)
        #expect(textSource.url == nil)

        let file = Inspiration(
            id: InspirationID(),
            inputKind: .file,
            rawText: nil,
            rawURL: nil,
            rawFile: FileReference(bookmarkData: Data([1]), displayName: "材料.pdf"),
            resolvedSourceKind: .document,
            resolvedMetadata: nil,
            categoryID: UUID(),
            lifecycle: .active,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let fileSource = try #require(MaterialSourceResolver.resolve(file))
        #expect(fileSource.descriptor.kind == .localFile)
        #expect(fileSource.fileReference == file.rawFile)
        #expect(fileSource.sourceTitle == "材料.pdf")
    }

    @Test func resolverKeepsXiaohongshuPlatformIdentityAndDropsTheQueryFromNoteID() throws {
        let source = try #require(MaterialSourceResolver.resolve(.url(
            "https://www.xiaohongshu.com/explore/6a7b2b1900000000220316a9?share=redacted",
            kind: .socialPost
        )))
        #expect(
            source.descriptor.kind
                == .xiaohongshuNote(noteID: "6a7b2b1900000000220316a9")
        )
        #expect(source.kind == .socialPost)

        let profile = try #require(MaterialSourceResolver.resolve(.url(
            "https://www.xiaohongshu.com/user/profile/123",
            kind: .unknown
        )))
        #expect(profile.descriptor.kind == .publicWebArticle)
    }
}

private extension Inspiration {
    static func url(_ raw: String, kind: ResolvedSourceKind) -> Inspiration {
        Inspiration(
            id: InspirationID(),
            inputKind: .url,
            rawText: nil,
            rawURL: URL(string: raw)!,
            rawFile: nil,
            resolvedSourceKind: kind,
            resolvedMetadata: nil,
            categoryID: UUID(uuidString: "00000000-0000-0000-0000-00000000d001")!,
            lifecycle: .active,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }
}

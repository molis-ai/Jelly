import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("SourceKindClassifierTests")
struct SourceKindClassifierTests {
    @Test func classifiesOnlySupportedMaterialPages() {
        let cases: [(String, ResolvedSourceKind?)] = [
            ("https://www.bilibili.com/video/BV1xx411c7mD/", .video),
            ("https://m.bilibili.com/video/av170001", .video),
            ("https://b23.tv/jKx2Ab", .video),
            ("https://www.bilibili.com/read/cv123", nil),
            ("https://space.bilibili.com/123", nil),
            ("https://www.xiaoyuzhoufm.com/episode/650a1b2ce1b3f16a04cb0f2e", .audio),
            ("https://www.xiaoyuzhoufm.com/podcast/5e2c8f0be1b3f16a04cb0f2e", nil),
            ("https://notbilibili.com/video/BV1", nil),
            ("https://fakexiaoyuzhoufm.com/episode/1", nil),
            ("https://example.com/post", nil),
            ("https://example.com/video/1", nil)
        ]
        for (raw, expected) in cases {
            #expect(SourceKindClassifier.classify(URL(string: raw)!) == expected)
        }
    }

    @Test func classifiesOnlyExactPublicXiaohongshuNotePaths() {
        let cases: [(String, ResolvedSourceKind?)] = [
            ("https://www.xiaohongshu.com/explore/6a7b2b1900000000220316a9", .socialPost),
            ("https://xiaohongshu.com/discovery/item/6a7b2b1900000000220316a9", .socialPost),
            ("https://www.xiaohongshu.com/user/profile/123", nil),
            ("https://www.xiaohongshu.com/explore/", nil),
            ("https://www.xiaohongshu.com/explore/id/extra", nil),
            ("https://fake-xiaohongshu.com/explore/1", nil),
            ("https://xiaohongshu.com.evil.test/explore/1", nil),
            ("http://www.xiaohongshu.com/explore/1", nil),
            ("https://www.xiaohongshu.com/explore/%2Fetc", nil)
        ]
        for (raw, expected) in cases {
            #expect(SourceKindClassifier.classify(URL(string: raw)!) == expected)
        }
    }
}

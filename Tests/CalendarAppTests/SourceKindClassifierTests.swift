import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("SourceKindClassifierTests")
struct SourceKindClassifierTests {
    @Test func classifiesKnownDomainsBeforeAnyNetworkRequest() {
        let cases: [(url: String, expected: ResolvedSourceKind?)] = [
            // B 站播放页 → video
            ("https://www.bilibili.com/video/BV1xx411c7mD/", .video),
            ("https://www.bilibili.com/video/BV1xx411c7mD?p=1", .video),
            ("https://m.bilibili.com/video/av170001", .video),
            // B 站短链域一律按视频处理
            ("https://b23.tv/jKx2Ab", .video),
            // 大小写不敏感
            ("https://WWW.BILIBILI.COM/VIDEO/BV1xx411c7mD", .video),
            // 小宇宙单集页 → audio；裸域同样成立
            ("https://www.xiaoyuzhoufm.com/episode/650a1b2ce1b3f16a04cb0f2e", .audio),
            ("https://xiaoyuzhoufm.com/episode/650a1b2ce1b3f16a04cb0f2e", .audio),
            // 节目首页不是单集，不要猜
            ("https://www.xiaoyuzhoufm.com/podcast/5e2c8f0be1b3f16a04cb0f2e", nil),
            // B 站专栏 / 空间 / 首页不当视频
            ("https://www.bilibili.com/read/cv123456", nil),
            ("https://space.bilibili.com/12345", nil),
            ("https://www.bilibili.com/", nil),
            // 相似域名不能误判
            ("https://fakexiaoyuzhoufm.com/episode/abc", nil),
            ("https://notbilibili.com/video/BV1xx411c7mD", nil),
            // 未知域名交给原有解析流程
            ("https://example.com/post", nil)
        ]
        for testCase in cases {
            let url = URL(string: testCase.url)!
            #expect(
                SourceKindClassifier.classify(url) == testCase.expected,
                "\(testCase.url) 应判定为 \(String(describing: testCase.expected))"
            )
        }
    }
}

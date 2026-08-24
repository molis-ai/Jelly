import Foundation
import WorkspaceDomain

/// 域名级来源分类：发网络请求之前即可判定，元数据解析失败时也能留下 kind。
/// 只做纯函数判断，不发网络；返回 nil 表示域名层面无法判定，交回原有解析流程。
enum SourceKindClassifier {
    static func classify(_ url: URL) -> ResolvedSourceKind? {
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.path.lowercased()
        // B 站短链一律指向视频分享页，按视频处理。
        if host == "b23.tv" { return .video }
        // B 站主站只有 /video/ 播放页按视频处理；专栏 /read/、空间页等不猜。
        if isHost(host, domain: "bilibili.com"), path.hasPrefix("/video/") {
            return .video
        }
        // 小宇宙单集页；节目首页 /podcast/ 不是单集，不要猜。
        if isHost(host, domain: "xiaoyuzhoufm.com"), path.hasPrefix("/episode/") {
            return .audio
        }
        return nil
    }

    private static func isHost(_ host: String, domain: String) -> Bool {
        host == domain || host.hasSuffix(".\(domain)")
    }
}

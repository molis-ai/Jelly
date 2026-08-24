import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("MaterialSourceProviderLiveTests")
struct MaterialSourceProviderLiveTests {
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["JELLY_RUN_LIVE_MATERIAL_PROBE"] == "1")
    )
    func liveBilibiliPublicVideoYieldsTranscriptOrAudio() async throws {
        let acquirer = RoutedMaterialAcquirer()
        let result = try await acquirer.acquire(
            MaterialSource(
                inspirationID: InspirationID(),
                url: URL(string: "https://www.bilibili.com/video/BV1xx411c7mD/")!,
                kind: .video,
                sourceChecksum: "live"
            )
        )
        switch result {
        case let .blocks(batch):
            print("LIVE_PROBE_RAN kind=video branch=transcript segments=\(batch.timestampedTranscript.segments.count)")
            #expect(!batch.blocks.isEmpty)
        case let .remoteMedia(asset):
            print("LIVE_PROBE_RAN kind=video branch=remoteAudio estimatedBytes=\(asset.estimatedBytes ?? -1)")
            #expect(asset.url.scheme?.lowercased() == "https")
        case .composite:
            Issue.record("Bilibili live probe must not return composite material")
        }
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["JELLY_RUN_LIVE_MATERIAL_PROBE"] == "1")
    )
    func liveXiaoyuzhouPublicEpisodeYieldsAudio() async throws {
        let acquirer = RoutedMaterialAcquirer()
        let result = try await acquirer.acquire(
            MaterialSource(
                inspirationID: InspirationID(),
                url: URL(string: "https://www.xiaoyuzhoufm.com/episode/69b6c67ef8b8079bfa7b7260")!,
                kind: .audio,
                sourceChecksum: "live"
            )
        )
        guard case let .remoteMedia(asset) = result else {
            Issue.record("expected xiaoyuzhou remote audio")
            return
        }
        print("LIVE_PROBE_RAN kind=audio branch=remoteAudio estimatedBytes=\(asset.estimatedBytes ?? -1)")
        #expect(asset.url.scheme?.lowercased() == "https")
    }

    @Test(
        .enabled(if:
            ProcessInfo.processInfo.environment["JELLY_RUN_LIVE_MATERIAL_PROBE"] == "1"
                && ProcessInfo.processInfo.environment["JELLY_XHS_LIVE_URL"] != nil
        )
    )
    func liveXiaohongshuURLYieldsCompositeMaterial() async throws {
        let raw = try #require(ProcessInfo.processInfo.environment["JELLY_XHS_LIVE_URL"])
        let url = try #require(URL(string: raw))
        let source = MaterialSource(
            inspirationID: InspirationID(),
            url: url,
            kind: .socialPost,
            sourceChecksum: "live"
        )
        let result = try await RoutedMaterialAcquirer().acquire(source)
        guard case let .composite(value) = result else {
            Issue.record("expected xiaohongshu composite acquisition")
            return
        }
        print(
            "LIVE_PROBE_RAN platform=xiaohongshu blocks=\(value.seedBlocks.count) "
                + "assets=\(value.expectedAssetCount)"
        )
        #expect(
            value.seedBlocks.contains(where: { $0.role != .metadata })
                || value.expectedAssetCount > 0
        )
    }
}

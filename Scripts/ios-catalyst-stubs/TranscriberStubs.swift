import Foundation
import WorkspaceDomain

// Stand-ins used only by Scripts/test-ios-catalyst.sh: the real transcribers
// need WhisperKit and FluidAudio, which are not built for Mac Catalyst here.
actor WhisperKitMaterialTranscriber: MaterialTranscribing {
    init(modelDirectory: URL) {}
    func modelRequirement() async -> MaterialModelRequirement { fatalError() }
    func prepareModel(progress: @escaping @Sendable (Double) -> Void) async throws {}
    func transcribe(_ fileURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> TimestampedTranscript { fatalError() }
}

actor SenseVoiceMaterialTranscriber: MaterialTranscribing {
    init() {}
    func modelRequirement() async -> MaterialModelRequirement { fatalError() }
    func prepareModel(progress: @escaping @Sendable (Double) -> Void) async throws {}
    func transcribe(_ fileURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> TimestampedTranscript { fatalError() }
}

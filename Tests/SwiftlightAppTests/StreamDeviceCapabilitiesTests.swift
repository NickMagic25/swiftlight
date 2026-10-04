import Foundation
import SwiftlightCore
import SwiftlightVideo
import Testing
@testable import SwiftlightApp

struct StreamDeviceCapabilitiesTests {
    @Test @MainActor func default420AndPyrowaveAvoidCompressedProfileProbes() async throws {
        let recorder = ProfileProbeRecorder()
        for codec in CodecPreference.allCases {
            var settings = StreamSettings(); settings.codec = codec
            let result = try await StreamDeviceCapabilities.resolve(settings: settings, hdrDisplay: true,
                profileProbe: { recorder.record($0, $1, $2); return true })
            #expect(!result.hevc444 && !result.hevcHDR444 && !result.av1444 && !result.av1HDR444)
        }
        var pyrowave = StreamSettings(); pyrowave.codec = .pyrowave; pyrowave.chromaSampling = .yuv444
        _ = try await StreamDeviceCapabilities.resolve(settings: pyrowave, hdrDisplay: true,
            profileProbe: { recorder.record($0, $1, $2); return true })
        #expect(recorder.calls.isEmpty)
    }

    @Test @MainActor func auto444ProbesEachExactProfileAwayFromTheUIThread() async throws {
        let recorder = ProfileProbeRecorder()
        var settings = StreamSettings(); settings.chromaSampling = .yuv444
        let result = try await StreamDeviceCapabilities.resolve(settings: settings, hdrDisplay: true,
            profileProbe: { codec, depth, chroma in
                recorder.record(codec, depth, chroma)
                return codec == .hevc || depth == 8
            })
        #expect(recorder.calls.map(\.profile) == ["hevc:8:3", "hevc:10:3", "av1:8:3", "av1:10:3"])
        #expect(recorder.calls.allSatisfy { !$0.mainThread })
        #expect(result.hevc444 && result.hevcHDR444 && result.av1444 && !result.av1HDR444)
    }

    @Test func forcedCodecAndSDRDisplayAvoidUnusedProfileProbes() async throws {
        for codec in [CodecPreference.hevc, .av1] {
            for hdrDisplay in [false, true] {
                let recorder = ProfileProbeRecorder()
                var settings = StreamSettings(); settings.codec = codec; settings.chromaSampling = .yuv444
                settings.hdr = hdrDisplay ? .off : .auto
                let result = try await StreamDeviceCapabilities.resolve(settings: settings, hdrDisplay: hdrDisplay,
                    profileProbe: { recorder.record($0, $1, $2); return true })
                #expect(recorder.calls.map(\.profile) == ["\(codec.rawValue):8:3"])
                #expect(!result.hevcHDR444 && !result.av1HDR444)
                #expect(result.hevc444 == (codec == .hevc))
                #expect(result.av1444 == (codec == .av1))
            }
        }
    }

    @Test func cancellationStopsAdmissionOfFurtherProbes() async throws {
        let recorder = ProfileProbeRecorder()
        let started = AsyncStream<Void>.makeStream()
        let gate = DispatchSemaphore(value: 0)
        var settings = StreamSettings(); settings.chromaSampling = .yuv444
        let captured = settings
        let task = Task {
            try await StreamDeviceCapabilities.resolve(settings: captured, hdrDisplay: true,
                profileProbe: { codec, depth, chroma in
                    recorder.record(codec, depth, chroma)
                    started.continuation.yield(())
                    _ = gate.wait(timeout: .now() + 5)
                    return true
                })
        }
        for await _ in started.stream { break }
        task.cancel(); gate.signal(); started.continuation.finish()
        do {
            _ = try await task.value
            Issue.record("Canceled profile probing must not produce launch capabilities")
        } catch is CancellationError {} catch {
            Issue.record("Expected CancellationError, received \(type(of: error))")
        }
        #expect(recorder.calls.count == 1)
    }
}

/// A synchronous native probe may run on a detached worker; all recorded state
/// is protected by this lock and no lock spans the potentially blocking probe.
private final class ProfileProbeRecorder: @unchecked Sendable {
    struct Call: Sendable {
        let profile: String
        let mainThread: Bool
    }
    private let lock = NSLock()
    private var recorded: [Call] = []
    var calls: [Call] { lock.withLock { recorded } }
    func record(_ codec: VideoCodec, _ depth: Int, _ chroma: Int) {
        let call = Call(profile: "\(codec.rawValue):\(depth):\(chroma)", mainThread: Thread.isMainThread)
        lock.withLock { recorded.append(call) }
    }
}

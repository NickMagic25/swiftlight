import Foundation
import SwiftlightCore
import Testing
@testable import SwiftlightApp

struct HDRRenderOptionsTests {
    @Test func settingsSelectOnlyHDROutput() throws {
        for mode in HDRPresentationMode.selectableModes {
            var settings = StreamSettings()
            settings.hdrPresentationMode = mode
            var original = StreamRenderOptions()
            original.captureScheduledCallback = false
            original.useFrameAutoreleasePool = false
            let resolved = original.resolvingHDRPresentation(settings: settings)
            #expect(resolved.hdrPresentationMode == settings.effectiveHDRPresentationMode)
            #expect(resolved.nativePQOutput == (settings.effectiveHDRPresentationMode == .nativePQ))
            #expect(resolved.captureScheduledCallback == original.captureScheduledCallback)
            #expect(resolved.useFrameAutoreleasePool == original.useFrameAutoreleasePool)
            #expect(resolved.useRootMetalLayer == original.useRootMetalLayer)
            #expect(resolved.showMetalHUD == original.showMetalHUD)
            let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(resolved)) as? [String: Any]
            #expect(json?["hdrPresentationMode"] as? String == resolved.hdrPresentationMode.rawValue)
            #expect(json?["nativePQOutput"] as? Bool == resolved.nativePQOutput)
        }
    }

    @Test func legacyExplicitPQTrialRemainsExplicit() {
        var original = StreamRenderOptions()
        original.nativePQOutput = true
        var settings = StreamSettings()
        settings.hdrPresentationMode = .linearUnmapped
        let resolved = original.resolvingHDRPresentation(settings: settings)
        #if DEBUG
        #expect(resolved.hdrPresentationMode == .nativePQ)
        #expect(resolved.nativePQOutput)
        #else
        #expect(resolved.hdrPresentationMode == .linearUnmapped)
        #expect(!resolved.nativePQOutput)
        #endif
    }

    @Test func defaultSettingsUsePQInBothConfigurations() {
        let resolved = StreamRenderOptions().resolvingHDRPresentation(settings: StreamSettings())
        #expect(resolved.hdrPresentationMode == .nativePQ)
        #expect(resolved.nativePQOutput)
    }

    @Test func internalSystemBaselineCanStillBeMeasured() {
        var settings = StreamSettings()
        settings.hdrPresentationMode = .systemToneMapped
        let resolved = StreamRenderOptions().resolvingHDRPresentation(settings: settings)
        #expect(resolved.hdrPresentationMode == .systemToneMapped)
        #expect(!resolved.nativePQOutput)
    }
}

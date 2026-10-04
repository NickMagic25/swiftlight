import Foundation
import Testing
import SwiftlightCore
import SwiftlightPlugins
@testable import SwiftlightApp

@Suite struct PluginLifecycleTests {
    @Test func failedAttemptsBeforeDecodedOutputDoNotEmitStartOrEnd() {
        for event in [SessionEvent.failure("Fixture failure"), .pathLost, .suspend, .disconnect] {
            var state = SessionState()
            var lifecycle = PluginStreamLifecycle()
            state.apply(.connect)
            let generation = state.generation
            lifecycle.prepare(context("attempt"), generation: generation)
            state.apply(event)
            #expect(lifecycle.takeEndContext() == nil)
            #expect(lifecycle.markStarted(generation: generation) == nil)
        }
    }

    @Test func repeatedFirstOutputAndRepeatedTeardownEmitExactlyOnePair() throws {
        var lifecycle = PluginStreamLifecycle()
        lifecycle.prepare(context("stream"), generation: 7)
        let started = lifecycle.markStarted(generation: 7)
        let start = try #require(started)
        #expect(lifecycle.markStarted(generation: 7) == nil)
        let ended = lifecycle.takeEndContext()
        let end = try #require(ended)
        #expect(end.sessionID == start.sessionID)
        #expect(lifecycle.takeEndContext() == nil)
        #expect(lifecycle.markStarted(generation: 7) == nil)
    }

    @Test func staleCallbacksCannotStartOrConsumeTheCurrentAttempt() throws {
        var lifecycle = PluginStreamLifecycle()
        lifecycle.prepare(context("new"), generation: 42)
        #expect(lifecycle.markStarted(generation: 41) == nil)
        let started = lifecycle.markStarted(generation: 42)
        #expect(try #require(started).sessionID == "new")
        #expect(lifecycle.markStarted(generation: 41) == nil)
        let ended = lifecycle.takeEndContext()
        #expect(try #require(ended).sessionID == "new")
    }

    @Test func retiringTheAttemptPreventsLateDecodedOutputFromRevivingIt() {
        var lifecycle = PluginStreamLifecycle()
        lifecycle.prepare(context("cancelled"), generation: 3)
        #expect(lifecycle.takeEndContext() == nil)
        #expect(lifecycle.markStarted(generation: 3) == nil)
        lifecycle.prepare(context("replacement"), generation: 5)
        #expect(lifecycle.markStarted(generation: 3) == nil)
        #expect(lifecycle.markStarted(generation: 5)?.sessionID == "replacement")
    }

    @Test func contextPreservesTheHostAndApplicationCapturedBeforeConnection() throws {
        var lifecycle = PluginStreamLifecycle()
        lifecycle.prepare(context("identity"), generation: 9)
        let started = lifecycle.markStarted(generation: 9)
        let start = try #require(started)
        // Taking the end snapshot before asynchronous teardown retains identity
        // even if UI host/app selection changes while native workers finish.
        let ended = lifecycle.takeEndContext()
        let end = try #require(ended)
        #expect(start.hostID == "host-id" && end.hostID == "host-id")
        #expect(start.hostName == "Computer" && end.hostName == "Computer")
        #expect(start.appID == 17 && end.appID == 17)
        #expect(start.appName == "Game" && end.appName == "Game")
        #expect(start.endReason == nil && end.endReason == nil)
    }

    @Test func reconnectRetiresOldSessionBeforePreparingTheNewOne() throws {
        var state = SessionState()
        var lifecycle = PluginStreamLifecycle()
        state.apply(.connect)
        let firstGeneration = state.generation
        lifecycle.prepare(context("first"), generation: firstGeneration)
        state.apply(.negotiated, generation: firstGeneration)
        state.apply(.firstFrame, generation: firstGeneration)
        let firstStart = lifecycle.markStarted(generation: state.generation)
        #expect(try #require(firstStart).sessionID == "first")
        state.apply(.disconnect)
        let ended = lifecycle.takeEndContext()
        let firstEnd = try #require(ended)
        #expect(firstEnd.sessionID == "first")
        state.apply(.stopped)
        state.apply(.connect)
        lifecycle.prepare(context("second"), generation: state.generation)
        #expect(lifecycle.markStarted(generation: firstGeneration) == nil)
        state.apply(.negotiated)
        state.apply(.firstFrame)
        let secondStart = lifecycle.markStarted(generation: state.generation)
        #expect(try #require(secondStart).sessionID == "second")
        let secondEnd = lifecycle.takeEndContext()
        #expect(try #require(secondEnd).sessionID == "second")
    }

    private func context(_ sessionID: String) -> PluginStreamContext {
        PluginStreamContext(sessionID: sessionID, hostID: "host-id", hostName: "Computer", appID: 17, appName: "Game")
    }
}

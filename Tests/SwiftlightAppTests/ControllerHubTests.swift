import Foundation
import GameController
import Testing
import SwiftlightCore
import SwiftlightTransport
@testable import SwiftlightApp

/// Snapshot controllers exercise the production routing/lifecycle without a
/// physical controller, an active streaming host, or synthetic UIKit key input.
@Suite(.serialized) @MainActor struct ControllerHubTests {
    @Test func changingMenuOwnerRetiresOldCallbacksAndOwnerSpecificClear() throws {
        let controller = GCController.withExtendedGamepad()
        let pad = try #require(controller.extendedGamepad)
        let hub = ControllerHub(controllerProvider: { [controller] })
        let oldOwner = UUID(), newOwner = UUID()
        var oldActions: [MenuControllerAction] = [], actions: [MenuControllerAction] = []
        hub.setMenuHandler(owner: oldOwner) { oldActions.append($0) }
        let retiredCallback = try #require(pad.valueChangedHandler)
        hub.setMenuHandler(owner: newOwner) { actions.append($0) }
        defer { hub.clearMenuHandler(owner: newOwner) }
        hub.clearMenuHandler(owner: oldOwner)
        set(pad.buttonA, value: 1, in: pad)
        retiredCallback(pad, pad.buttonA)
        #expect(oldActions.isEmpty && actions.isEmpty)
        pad.valueChangedHandler?(pad, pad.buttonA)
        #expect(actions == [.activate])
    }

    @Test func clearedMenuRouteCannotReceiveAQueuedCallback() throws {
        let controller = GCController.withExtendedGamepad()
        let pad = try #require(controller.extendedGamepad)
        let hub = ControllerHub(controllerProvider: { [controller] })
        let owner = UUID()
        var actions: [MenuControllerAction] = []
        hub.setMenuHandler(owner: owner) { actions.append($0) }
        let retiredCallback = try #require(pad.valueChangedHandler)
        hub.clearMenuHandler(owner: owner)
        #expect(pad.valueChangedHandler == nil)
        set(pad.buttonA, value: 1, in: pad)
        retiredCallback(pad, pad.buttonA)
        #expect(actions.isEmpty)
        #expect(controller.playerIndex == .indexUnset)
    }

    @Test func streamCaptureHasExclusivePriorityAndRestoresMenuSafely() throws {
        let controller = GCController.withExtendedGamepad()
        let pad = try #require(controller.extendedGamepad)
        let originalQueue = DispatchQueue(label: "net.swiftlight.tests.controller")
        controller.handlerQueue = originalQueue
        pad.buttonA.preferredSystemGestureState = .enabled
        let homeGesture = pad.buttonHome?.preferredSystemGestureState
        let hub = ControllerHub(controllerProvider: { [controller] })
        let owner = UUID()
        var actions: [MenuControllerAction] = []
        hub.setMenuHandler(owner: owner) { actions.append($0) }
        defer { hub.stop(); hub.clearMenuHandler(owner: owner) }
        let oldMenuCallback = try #require(pad.valueChangedHandler)
        hub.start(transport: try makeTransport())
        #expect(pad.buttonA.preferredSystemGestureState == .disabled)
        #expect(pad.buttonHome?.preferredSystemGestureState == .disabled)
        let oldStreamCallback = try #require(pad.valueChangedHandler)
        set(pad.buttonA, value: 1, in: pad)
        oldMenuCallback(pad, pad.buttonA)
        oldStreamCallback(pad, pad.buttonA)
        #expect(actions.isEmpty)
        hub.stop()
        #expect(pad.buttonA.preferredSystemGestureState == .enabled)
        #expect(pad.buttonHome?.preferredSystemGestureState == homeGesture)
        // A held at capture release must not select a menu item automatically.
        oldStreamCallback(pad, pad.buttonA)
        pad.valueChangedHandler?(pad, pad.buttonA)
        #expect(actions.isEmpty)
        set(pad.buttonA, value: 0, in: pad); pad.valueChangedHandler?(pad, pad.buttonA)
        set(pad.buttonA, value: 1, in: pad); pad.valueChangedHandler?(pad, pad.buttonA)
        #expect(actions == [.activate])
        hub.clearMenuHandler(owner: owner)
        #expect(controller.handlerQueue === originalQueue)
    }

    @Test func receivedGuideEdgesPreserveOtherGameplayInputs() throws {
        let controller = GCController.withExtendedGamepad()
        let pad = try #require(controller.extendedGamepad)
        let home = try #require(pad.buttonHome)
        let transport = try makeTransport()
        var samples: [ControllerSentSample] = []
        let hub = ControllerHub(controllerProvider: { [controller] }, controllerSender: { transport, index, mask, input in
            samples.append(.init(transport: ObjectIdentifier(transport), index: index, activeMask: mask, input: input))
        })
        hub.start(transport: transport)
        defer { hub.stop() }
        samples.removeAll()
        set(pad.buttonA, value: 1, in: pad)
        set(pad.leftTrigger, value: 0.5, in: pad)
        set(pad.leftThumbstick.xAxis, value: 0.25, in: pad)
        // These are framework-delivered Home edges. Snapshot controllers do not
        // exercise the system's single/double-press gesture recognizer.
        set(home, value: 1, in: pad); pad.valueChangedHandler?(pad, home)
        set(home, value: 0, in: pad); pad.valueChangedHandler?(pad, home)
        #expect(samples == [
            .init(transport: ObjectIdentifier(transport), index: 0, activeMask: 1,
                  input: .init(buttons: [.a, .guide], leftTrigger: 0.5, leftX: 0.25)),
            .init(transport: ObjectIdentifier(transport), index: 0, activeMask: 1,
                  input: .init(buttons: [.a], leftTrigger: 0.5, leftX: 0.25))])
    }

    @Test func guideIsIgnoredByTheMenuRoute() throws {
        let controller = GCController.withExtendedGamepad()
        let pad = try #require(controller.extendedGamepad)
        let home = try #require(pad.buttonHome)
        let originalGesture = home.preferredSystemGestureState
        var samples: [ControllerSentSample] = []
        var actions: [MenuControllerAction] = []
        let hub = ControllerHub(controllerProvider: { [controller] }, controllerSender: { transport, index, mask, input in
            samples.append(.init(transport: ObjectIdentifier(transport), index: index, activeMask: mask, input: input))
        })
        let owner = UUID()
        hub.setMenuHandler(owner: owner) { actions.append($0) }
        defer { hub.clearMenuHandler(owner: owner) }
        set(home, value: 1, in: pad); pad.valueChangedHandler?(pad, home)
        set(home, value: 0, in: pad); pad.valueChangedHandler?(pad, home)
        #expect(actions.isEmpty && samples.isEmpty)
        #expect(home.preferredSystemGestureState == originalGesture)
        set(home, value: 1, in: pad)
        set(pad.buttonA, value: 1, in: pad); pad.valueChangedHandler?(pad, pad.buttonA)
        #expect(actions == [.activate])
        #expect(samples.isEmpty)
    }

    @Test func heldGuideAndRetiredCallbacksCannotLeakIntoResumedCapture() throws {
        let controller = GCController.withExtendedGamepad()
        let pad = try #require(controller.extendedGamepad)
        let home = try #require(pad.buttonHome)
        let originalGesture = home.preferredSystemGestureState
        let firstTransport = try makeTransport(), resumedTransport = try makeTransport()
        var samples: [ControllerSentSample] = []
        let hub = ControllerHub(controllerProvider: { [controller] }, controllerSender: { transport, index, mask, input in
            samples.append(.init(transport: ObjectIdentifier(transport), index: index, activeMask: mask, input: input))
        })
        set(home, value: 1, in: pad)
        hub.start(transport: firstTransport)
        defer { hub.stop() }
        let retiredCallback = try #require(pad.valueChangedHandler)
        retiredCallback(pad, home)
        #expect(samples.count == 2 && samples.allSatisfy { $0.input == .neutral })
        hub.stop()
        #expect(home.preferredSystemGestureState == originalGesture)
        hub.start(transport: resumedTransport)
        #expect(home.preferredSystemGestureState == .disabled)
        #expect(samples.last?.input == .neutral)
        samples.removeAll()
        set(home, value: 0, in: pad); retiredCallback(pad, home)
        #expect(samples.isEmpty)
        pad.valueChangedHandler?(pad, home)
        set(home, value: 1, in: pad); retiredCallback(pad, home)
        #expect(samples.count == 1)
        pad.valueChangedHandler?(pad, home)
        #expect(samples == [
            .init(transport: ObjectIdentifier(resumedTransport), index: 0, activeMask: 1, input: .neutral),
            .init(transport: ObjectIdentifier(resumedTransport), index: 0, activeMask: 1, input: .init(buttons: [.guide]))])
    }

    @Test func guideHotRemovalSendsNeutralAndRestoresGesturePreferences() throws {
        let controller = GCController.withExtendedGamepad(), replacement = GCController.withExtendedGamepad()
        let pad = try #require(controller.extendedGamepad), replacementPad = try #require(replacement.extendedGamepad)
        let home = try #require(pad.buttonHome), replacementHome = try #require(replacementPad.buttonHome)
        let originalGesture = home.preferredSystemGestureState
        let replacementGesture = replacementHome.preferredSystemGestureState
        let devices = ControllerList([controller])
        let transport = try makeTransport()
        var samples: [ControllerSentSample] = []
        let hub = ControllerHub(controllerProvider: { devices.values }, controllerSender: { transport, index, mask, input in
            samples.append(.init(transport: ObjectIdentifier(transport), index: index, activeMask: mask, input: input))
        })
        hub.start(transport: transport)
        defer { hub.stop() }
        set(home, value: 1, in: pad); pad.valueChangedHandler?(pad, home)
        #expect(samples.last?.input.buttons == [.guide])
        let retiredCallback = try #require(pad.valueChangedHandler)
        samples.removeAll()
        devices.values = []
        NotificationCenter.default.post(name: .GCControllerDidDisconnect, object: controller)
        #expect(samples == [.init(transport: ObjectIdentifier(transport), index: 0, activeMask: 0, input: .neutral)])
        #expect(home.preferredSystemGestureState == originalGesture)
        #expect(pad.valueChangedHandler == nil && controller.playerIndex == .indexUnset)
        retiredCallback(pad, home)
        #expect(samples.count == 1)
        // A replacement holding Home cannot inherit the removed player's press.
        set(replacementHome, value: 1, in: replacementPad)
        devices.values = [replacement]
        NotificationCenter.default.post(name: .GCControllerDidConnect, object: replacement)
        #expect(replacementHome.preferredSystemGestureState == .disabled)
        #expect(samples.last == .init(transport: ObjectIdentifier(transport), index: 0, activeMask: 1, input: .neutral))
        replacementPad.valueChangedHandler?(replacementPad, replacementHome)
        #expect(samples.last?.input == .neutral)
        set(replacementHome, value: 0, in: replacementPad); replacementPad.valueChangedHandler?(replacementPad, replacementHome)
        set(replacementHome, value: 1, in: replacementPad); replacementPad.valueChangedHandler?(replacementPad, replacementHome)
        #expect(samples.last?.input.buttons == [.guide])
        hub.stop()
        #expect(replacementHome.preferredSystemGestureState == replacementGesture)
    }

    @Test func hotPlugKeepsSurvivingPlayerIndicesAndRetiresOldDeviceCallbacks() throws {
        let first = GCController.withExtendedGamepad(), second = GCController.withExtendedGamepad()
        let replacement = GCController.withExtendedGamepad()
        let unsupported = GCController.withMicroGamepad()
        // Apple snapshot factories default playerIndex to raw 0, unlike an
        // unassigned physical fixture. Seed the ignored device explicitly.
        #expect(unsupported.extendedGamepad == nil)
        unsupported.playerIndex = .indexUnset
        let devices = ControllerList([unsupported, first, second])
        let hub = ControllerHub(controllerProvider: { devices.values })
        let owner = UUID()
        var actions: [MenuControllerAction] = []
        hub.setMenuHandler(owner: owner) { actions.append($0) }
        defer { hub.clearMenuHandler(owner: owner) }
        #expect(unsupported.playerIndex == .indexUnset)
        #expect(first.playerIndex == .index1 && second.playerIndex == .index2)
        let pad = try #require(first.extendedGamepad)
        let retiredCallback = try #require(pad.valueChangedHandler)
        devices.values = [second, replacement]
        NotificationCenter.default.post(name: .GCControllerDidDisconnect, object: first)
        #expect(second.playerIndex == .index2 && replacement.playerIndex == .index1)
        #expect(first.playerIndex == .indexUnset && pad.valueChangedHandler == nil)
        set(pad.buttonA, value: 1, in: pad); retiredCallback(pad, pad.buttonA)
        #expect(actions.isEmpty)
    }

    @Test func controllerLimitCountsOnlySupportedProfiles() {
        let unsupported = GCController.withMicroGamepad()
        let controllers = (0..<5).map { _ in GCController.withExtendedGamepad() }
        #expect(unsupported.extendedGamepad == nil)
        unsupported.playerIndex = .indexUnset
        for controller in controllers { controller.playerIndex = .indexUnset }
        let hub = ControllerHub(controllerProvider: { [unsupported] + controllers })
        let owner = UUID()
        hub.setMenuHandler(owner: owner) { _ in }
        defer { hub.clearMenuHandler(owner: owner) }
        #expect(unsupported.playerIndex == .indexUnset)
        #expect(controllers.map(\.playerIndex) == [.index1, .index2, .index3, .index4, .indexUnset])
    }

    private func makeTransport() throws -> StreamTransport {
        let configuration = TransportConfiguration(address: "localhost", appVersion: "7.1.431.0", rtspURL: nil,
            serverCodecSupport: 0x100, width: 1920, height: 1080, fps: 60, bitrateKbps: 20000,
            supportedVideoFormats: 0x100, inputKey: Data(repeating: 1, count: 16), inputKeyID: 1)
        return try StreamTransport(configuration: configuration,
            callbacks: .init(setup: { _ in true }, video: { _ in true }, event: { _ in }))
    }

    private func set(_ button: GCControllerButtonInput, value: Float, in pad: GCExtendedGamepad) {
        // Invoke the captured production callback explicitly at each boundary;
        // snapshot write delivery must not make these assertions timing-dependent.
        let callback = pad.valueChangedHandler
        pad.valueChangedHandler = nil; button.setValue(value); pad.valueChangedHandler = callback
    }

    private func set(_ axis: GCControllerAxisInput, value: Float, in pad: GCExtendedGamepad) {
        let callback = pad.valueChangedHandler
        pad.valueChangedHandler = nil; axis.setValue(value); pad.valueChangedHandler = callback
    }
}

private struct ControllerSentSample: Equatable {
    let transport: ObjectIdentifier
    let index: UInt8
    let activeMask: UInt16
    let input: ControllerInputState
}

@MainActor private final class ControllerList {
    var values: [GCController]
    init(_ values: [GCController]) { self.values = values }
}

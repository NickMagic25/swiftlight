import Foundation
import GameController
import CoreHaptics
import SwiftlightTransport

@MainActor final class ControllerHub {
    static let shared = ControllerHub()
    private var transport: StreamTransport?
    private var controllers: [GCController] = []
    private var observers: [NSObjectProtocol] = []
    private var engines: [Int: CHHapticEngine] = [:]
    private var players: [Int: CHHapticAdvancedPatternPlayer] = [:]
    func start(transport: StreamTransport) {
        stop(); self.transport = transport
        for name in [NSNotification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }
    private func refresh() {
        for player in players.values { try? player.stop(atTime: CHHapticTimeImmediate) }; players = [:]
        for engine in engines.values { engine.stop(completionHandler: nil) }; engines = [:]
        for controller in controllers { controller.extendedGamepad?.valueChangedHandler = nil }
        transport?.releaseAllInputs(); controllers = Array(GCController.controllers().prefix(4))
        guard let transport else { return }
        let mask = UInt16((1 << controllers.count) - 1)
        for (index, controller) in controllers.enumerated() {
            controller.playerIndex = GCControllerPlayerIndex(rawValue: index) ?? .indexUnset
            controller.extendedGamepad?.valueChangedHandler = { pad, _ in
                var buttons: UInt32 = 0
                let values: [(GCControllerButtonInput?, UInt32)] = [
                    (pad.buttonA,0x1000),(pad.buttonB,0x2000),(pad.buttonX,0x4000),(pad.buttonY,0x8000),
                    (pad.dpad.up,1),(pad.dpad.down,2),(pad.dpad.left,4),(pad.dpad.right,8),
                    (pad.leftShoulder,0x100),(pad.rightShoulder,0x200),(pad.buttonMenu,0x10),(pad.buttonOptions,0x20),
                    (pad.leftThumbstickButton,0x40),(pad.rightThumbstickButton,0x80)]
                for (button, flag) in values where button?.isPressed == true { buttons |= flag }
                transport.controller(index: UInt8(index), activeMask: mask, buttons: buttons,
                    leftTrigger: UInt8(clamping: Int(pad.leftTrigger.value * 255)), rightTrigger: UInt8(clamping: Int(pad.rightTrigger.value * 255)),
                    leftX: Int16(clamping: Int(pad.leftThumbstick.xAxis.value * 32767)), leftY: Int16(clamping: Int(pad.leftThumbstick.yAxis.value * 32767)),
                    rightX: Int16(clamping: Int(pad.rightThumbstick.xAxis.value * 32767)), rightY: Int16(clamping: Int(pad.rightThumbstick.yAxis.value * 32767)))
            }
        }
    }
    func rumble(index: Int, low: UInt16, high: UInt16) {
        guard controllers.indices.contains(index), let haptics = controllers[index].haptics else { return }
        do {
            try players[index]?.stop(atTime: CHHapticTimeImmediate)
            guard low != 0 || high != 0 else { return }
            let engine = engines[index] ?? haptics.createEngine(withLocality: .default)
            guard let engine else { return }; engines[index] = engine; try engine.start()
            let intensity = Float(max(low, high)) / Float(UInt16.max)
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(high) / Float(UInt16.max))], relativeTime: 0, duration: 1)
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makeAdvancedPlayer(with: pattern); player.loopEnabled = true; players[index] = player; try player.start(atTime: CHHapticTimeImmediate)
        } catch { /* Optional controller haptics can disappear on hot unplug. Input remains active. */ }
    }
    func stop() {
        for controller in controllers { controller.extendedGamepad?.valueChangedHandler = nil }
        controllers = []; transport?.releaseAllInputs(); transport = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers = []
        for player in players.values { try? player.stop(atTime: CHHapticTimeImmediate) }; players = [:]
        for engine in engines.values { engine.stop(completionHandler: nil) }; engines = [:]
    }
}

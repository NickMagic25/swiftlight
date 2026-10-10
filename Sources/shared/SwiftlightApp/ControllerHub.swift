import Foundation
import GameController
import CoreHaptics
import SwiftlightCore
import SwiftlightTransport

/// Owns each controller's profile callbacks. Stream capture has exclusive
/// priority over local navigation; route generations retire queued callbacks.
@MainActor final class ControllerHub {
    static let shared = ControllerHub()
    private let controllerProvider: @MainActor () -> [GCController]
    private let controllerSender: @MainActor (StreamTransport, UInt8, UInt16, ControllerInputState) -> Void
    private var transport: StreamTransport?
    private var controllers: [Int: GCController] = [:]
    private var observers: [NSObjectProtocol] = []
    private var engines: [Int: CHHapticEngine] = [:]
    private var players: [Int: CHHapticAdvancedPatternPlayer] = [:]
    private var handlerQueues: [Int: DispatchQueue] = [:]
    private var gesturePreferences: [(GCControllerElement, GCControllerElement.SystemGestureState)] = []
    private var streamAdmission: [Int: ControllerInputState.Admission] = [:]
    private var navigation: [Int: ControllerMenuInputState] = [:]
    private var menuOwner: UUID?
    private var menuHandler: (@MainActor (MenuControllerAction) -> Void)?
    private var repeatTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(controllerProvider: @escaping @MainActor () -> [GCController] = { GCController.controllers() },
         controllerSender: @escaping @MainActor (StreamTransport, UInt8, UInt16, ControllerInputState) -> Void = { transport, index, mask, input in
             transport.controller(index: index, activeMask: mask, buttons: input.buttons.rawValue,
                 leftTrigger: input.leftTrigger, rightTrigger: input.rightTrigger,
                 leftX: input.leftX, leftY: input.leftY, rightX: input.rightX, rightY: input.rightY)
         }) {
        self.controllerProvider = controllerProvider
        self.controllerSender = controllerSender
    }

    func setMenuHandler(owner: UUID, handler: @escaping @MainActor (MenuControllerAction) -> Void) {
        let changedOwner = menuOwner != owner
        menuOwner = owner; menuHandler = handler
        observeControllers()
        if transport == nil { refresh(resetAdmission: changedOwner) }
    }
    func clearMenuHandler(owner: UUID) {
        guard menuOwner == owner else { return }
        menuOwner = nil; menuHandler = nil
        if transport == nil { deactivate() }
    }
    func start(transport: StreamTransport) {
        guard self.transport !== transport else { return }
        retireCallbacks()
        self.transport?.releaseAllInputs()
        stopHaptics()
        self.transport = transport
        observeControllers()
        refresh(resetAdmission: true)
    }
    /// Release stream input without discarding an independently owned menu route.
    func stop() {
        guard let transport else { return }
        retireCallbacks()
        transport.releaseAllInputs(); self.transport = nil
        stopHaptics()
        if menuHandler != nil { refresh(resetAdmission: true) }
        else { deactivate() }
    }

    private func observeControllers() {
        guard observers.isEmpty else { return }
        for name in [NSNotification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh(resetAdmission: false) }
            })
        }
    }

    private var activeMask: UInt16 {
        controllers.keys.reduce(0) { $0 | (UInt16(1) << $1) }
    }
    private func refresh(resetAdmission: Bool) {
        let previous = controllers
        retireCallbacks()
        // Unsupported profiles do not occupy a host controller slot. Preserve
        // surviving player indices when another controller is connected/unplugged.
        let available = controllerProvider().filter { $0.extendedGamepad != nil }
        controllers = previous.filter { _, controller in available.contains { $0 === controller } }
        for controller in available where !controllers.values.contains(where: { $0 === controller }) {
            guard let index = (0..<4).first(where: { controllers[$0] == nil }) else { break }
            controllers[index] = controller
        }
        if resetAdmission { streamAdmission = [:]; navigation = [:] }
        for (index, controller) in previous where controllers[index] !== controller {
            controller.playerIndex = .indexUnset
            streamAdmission[index] = nil; navigation[index] = nil
            try? players.removeValue(forKey: index)?.stop(atTime: CHHapticTimeImmediate)
            engines.removeValue(forKey: index)?.stop(completionHandler: nil)
            // Advertise the new mask even when the final device disappears and
            // there can no longer be a value-changed event from another device.
            send(.neutral, index: index)
        }
        let callbackGeneration = generation
        for (index, controller) in controllers.sorted(by: { $0.key < $1.key }) {
            guard let pad = controller.extendedGamepad else { continue }
            controller.playerIndex = GCControllerPlayerIndex(rawValue: index) ?? .indexUnset
            handlerQueues[index] = controller.handlerQueue
            controller.handlerQueue = .main
            if transport != nil {
                // Request direct events only for mapped stream controls. The
                // OS still arbitrates Home's Game Overlay gesture; iOS 26 can
                // deliver a double press to the app. Forward its delivered
                // edges without another timer and restore the preference later.
                for element in Self.gameplayElements(pad) {
                    gesturePreferences.append((element, element.preferredSystemGestureState))
                    element.preferredSystemGestureState = .disabled
                }
            }
            let current = Self.sample(pad)
            if streamAdmission[index] == nil { streamAdmission[index] = .init(held: current) }
            if navigation[index] == nil { navigation[index] = .init(held: current) }
            pad.valueChangedHandler = { [weak self] pad, _ in
                // handlerQueue is explicitly main. Never retain a transport in
                // this callback: a retired callback cannot target a new stream.
                MainActor.assumeIsolated {
                    self?.receive(Self.sample(pad), index: index, generation: callbackGeneration)
                }
            }
            if transport != nil, var admission = streamAdmission[index] {
                send(admission.admit(current), index: index)
                streamAdmission[index] = admission
            }
        }
        scheduleRepeatIfNeeded()
    }

    private func receive(_ input: ControllerInputState, index: Int, generation callbackGeneration: UInt64) {
        guard callbackGeneration == generation, controllers[index] != nil else { return }
        if transport != nil, var admission = streamAdmission[index] {
            let accepted = admission.admit(input); streamAdmission[index] = admission
            send(accepted, index: index)
        } else if menuHandler != nil, var state = navigation[index] {
            let actions = state.consume(input, at: ProcessInfo.processInfo.systemUptime)
            navigation[index] = state
            deliver(actions, generation: callbackGeneration)
            scheduleRepeatIfNeeded()
        }
    }
    private func send(_ input: ControllerInputState, index: Int) {
        guard let transport else { return }
        controllerSender(transport, UInt8(index), activeMask, input)
    }
    private static func buttonMappings(_ pad: GCExtendedGamepad) -> [(GCControllerButtonInput?, ControllerButtons)] {
        [
            (pad.buttonA, .a), (pad.buttonB, .b), (pad.buttonX, .x), (pad.buttonY, .y),
            (pad.dpad.up, .up), (pad.dpad.down, .down), (pad.dpad.left, .left), (pad.dpad.right, .right),
            (pad.leftShoulder, .leftShoulder), (pad.rightShoulder, .rightShoulder),
            (pad.buttonMenu, .menu), (pad.buttonOptions, .options), (pad.buttonHome, .guide),
            (pad.leftThumbstickButton, .leftStick), (pad.rightThumbstickButton, .rightStick)]
    }
    private static func gameplayElements(_ pad: GCExtendedGamepad) -> [GCControllerElement] {
        var elements: [GCControllerElement] = buttonMappings(pad).compactMap { $0.0 }
        elements += [pad.leftTrigger, pad.rightTrigger,
            pad.dpad, pad.dpad.xAxis, pad.dpad.yAxis,
            pad.leftThumbstick, pad.leftThumbstick.xAxis, pad.leftThumbstick.yAxis,
            pad.rightThumbstick, pad.rightThumbstick.xAxis, pad.rightThumbstick.yAxis]
        var seen: Set<ObjectIdentifier> = []
        return elements.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }
    private static func sample(_ pad: GCExtendedGamepad) -> ControllerInputState {
        var buttons: ControllerButtons = []
        for (button, flag) in buttonMappings(pad) where button?.isPressed == true { buttons.insert(flag) }
        return ControllerInputState(buttons: buttons, leftTrigger: pad.leftTrigger.value, rightTrigger: pad.rightTrigger.value,
            leftX: pad.leftThumbstick.xAxis.value, leftY: pad.leftThumbstick.yAxis.value,
            rightX: pad.rightThumbstick.xAxis.value, rightY: pad.rightThumbstick.yAxis.value)
    }

    private func deliver(_ actions: [MenuControllerAction], generation callbackGeneration: UInt64) {
        for action in actions {
            guard generation == callbackGeneration, transport == nil, let menuHandler else { return }
            menuHandler(action)
        }
    }
    private func scheduleRepeatIfNeeded() {
        guard transport == nil, menuHandler != nil, navigation.values.contains(where: \.isRepeating) else {
            repeatTask?.cancel(); repeatTask = nil; return
        }
        guard repeatTask == nil else { return }
        let callbackGeneration = generation
        repeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
                guard let self, self.generation == callbackGeneration, self.transport == nil else { return }
                let now = ProcessInfo.processInfo.systemUptime
                for index in self.navigation.keys.sorted() {
                    guard var state = self.navigation[index] else { continue }
                    let action = state.repeatAction(at: now)
                    self.navigation[index] = state
                    if let action { self.deliver([action], generation: callbackGeneration) }
                    guard self.generation == callbackGeneration else { return }
                }
                if !self.navigation.values.contains(where: \.isRepeating) {
                    self.repeatTask = nil; return
                }
            }
        }
    }

    private func retireCallbacks() {
        generation &+= 1
        repeatTask?.cancel(); repeatTask = nil
        for (index, controller) in controllers {
            controller.extendedGamepad?.valueChangedHandler = nil
            if let queue = handlerQueues[index] { controller.handlerQueue = queue }
        }
        handlerQueues = [:]
        for (element, preference) in gesturePreferences { element.preferredSystemGestureState = preference }
        gesturePreferences = []
    }
    private func deactivate() {
        retireCallbacks()
        for controller in controllers.values { controller.playerIndex = .indexUnset }
        controllers = [:]; streamAdmission = [:]; navigation = [:]
        for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers = []
        stopHaptics()
    }
    private func stopHaptics() {
        for player in players.values { try? player.stop(atTime: CHHapticTimeImmediate) }; players = [:]
        for engine in engines.values { engine.stop(completionHandler: nil) }; engines = [:]
    }
    func rumble(index: Int, low: UInt16, high: UInt16) {
        guard transport != nil, let haptics = controllers[index]?.haptics else { return }
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
}

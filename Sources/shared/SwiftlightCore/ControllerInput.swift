import Foundation

/// GameStream button bits, shared by the native controller adapter and menu routing.
public struct ControllerButtons: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let up = Self(rawValue: 0x0001)
    public static let down = Self(rawValue: 0x0002)
    public static let left = Self(rawValue: 0x0004)
    public static let right = Self(rawValue: 0x0008)
    public static let menu = Self(rawValue: 0x0010)
    public static let options = Self(rawValue: 0x0020)
    public static let leftStick = Self(rawValue: 0x0040)
    public static let rightStick = Self(rawValue: 0x0080)
    public static let leftShoulder = Self(rawValue: 0x0100)
    public static let rightShoulder = Self(rawValue: 0x0200)
    public static let guide = Self(rawValue: 0x0400)
    public static let a = Self(rawValue: 0x1000)
    public static let b = Self(rawValue: 0x2000)
    public static let x = Self(rawValue: 0x4000)
    public static let y = Self(rawValue: 0x8000)
}

/// A bounded, value-owned sample. The platform framework already applies the
/// controller's dead zone; streaming does not add another one here.
public struct ControllerInputState: Equatable, Sendable {
    public let buttons: ControllerButtons
    public let leftTrigger, rightTrigger: UInt8
    public let leftX, leftY, rightX, rightY: Int16
    public static let neutral = Self()
    public init(buttons: ControllerButtons = [], leftTrigger: Float = 0, rightTrigger: Float = 0,
                leftX: Float = 0, leftY: Float = 0, rightX: Float = 0, rightY: Float = 0) {
        self.buttons = buttons
        self.leftTrigger = Self.trigger(leftTrigger); self.rightTrigger = Self.trigger(rightTrigger)
        self.leftX = Self.axis(leftX); self.leftY = Self.axis(leftY)
        self.rightX = Self.axis(rightX); self.rightY = Self.axis(rightY)
    }
    private init(buttons: ControllerButtons, leftTrigger: UInt8, rightTrigger: UInt8,
                 leftX: Int16, leftY: Int16, rightX: Int16, rightY: Int16) {
        self.buttons = buttons; self.leftTrigger = leftTrigger; self.rightTrigger = rightTrigger
        self.leftX = leftX; self.leftY = leftY; self.rightX = rightX; self.rightY = rightY
    }
    private static func trigger(_ value: Float) -> UInt8 {
        guard value.isFinite else { return 0 }
        return UInt8(min(1, max(0, value)) * 255)
    }
    private static func axis(_ value: Float) -> Int16 {
        guard value.isFinite else { return 0 }
        return Int16(min(1, max(-1, value)) * 32767)
    }

    /// Suppress controls held when the route was acquired until they return to
    /// neutral. Selecting a game with A must not also press A in that game, and
    /// capture resumption must not resurrect input released during suspension.
    public struct Admission: Sendable {
        private var buttons: ControllerButtons
        private var leftTrigger, rightTrigger, leftStick, rightStick: Bool
        public init(held input: ControllerInputState) {
            buttons = input.buttons
            leftTrigger = input.leftTrigger != 0; rightTrigger = input.rightTrigger != 0
            leftStick = input.leftX != 0 || input.leftY != 0
            rightStick = input.rightX != 0 || input.rightY != 0
        }
        public mutating func admit(_ input: ControllerInputState) -> ControllerInputState {
            buttons.formIntersection(input.buttons)
            if input.leftTrigger == 0 { leftTrigger = false }
            if input.rightTrigger == 0 { rightTrigger = false }
            if input.leftX == 0 && input.leftY == 0 { leftStick = false }
            if input.rightX == 0 && input.rightY == 0 { rightStick = false }
            return ControllerInputState(buttons: input.buttons.subtracting(buttons),
                leftTrigger: leftTrigger ? 0 : input.leftTrigger, rightTrigger: rightTrigger ? 0 : input.rightTrigger,
                leftX: leftStick ? 0 : input.leftX, leftY: leftStick ? 0 : input.leftY,
                rightX: rightStick ? 0 : input.rightX, rightY: rightStick ? 0 : input.rightY)
        }
    }
}

public enum MenuControllerDirection: Equatable, Sendable { case up, down, left, right }
public enum MenuControllerAction: Equatable, Sendable {
    case move(MenuControllerDirection)
    case activate, back, settings
}

/// Edge-triggered menu commands with hysteresis and one bounded repeat per tick.
/// Input values remain independent of display layout and platform UI frameworks.
public struct ControllerMenuInputState: Sendable {
    private var previousButtons: ControllerButtons = []
    private var direction: MenuControllerDirection?
    private var nextRepeat: TimeInterval?
    public var isRepeating: Bool { nextRepeat != nil }
    public init(held input: ControllerInputState = .neutral) {
        previousButtons = input.buttons
        direction = Self.direction(input, previous: nil)
    }
    public mutating func consume(_ input: ControllerInputState, at time: TimeInterval) -> [MenuControllerAction] {
        let pressed = input.buttons.subtracting(previousButtons)
        previousButtons = input.buttons
        let nextDirection = Self.direction(input, previous: direction)
        var actions: [MenuControllerAction] = []
        if nextDirection != direction {
            direction = nextDirection
            nextRepeat = nextDirection == nil ? nil : time + 0.4
            if let nextDirection { actions.append(.move(nextDirection)) }
        } else if let action = repeatAction(at: time) { actions.append(action) }
        // Conflicting face-button edges never activate and cancel in one sample.
        if pressed.contains(.b) { actions.append(.back) }
        else if pressed.contains(.menu) { actions.append(.settings) }
        else if pressed.contains(.a) { actions.append(.activate) }
        return actions
    }
    public mutating func repeatAction(at time: TimeInterval) -> MenuControllerAction? {
        guard let direction, let nextRepeat, time.isFinite, time >= nextRepeat else { return nil }
        self.nextRepeat = time + 0.12
        return .move(direction)
    }
    private static func direction(_ input: ControllerInputState, previous: MenuControllerDirection?) -> MenuControllerDirection? {
        let digitalX = (input.buttons.contains(.right) ? 1 : 0) - (input.buttons.contains(.left) ? 1 : 0)
        let digitalY = (input.buttons.contains(.up) ? 1 : 0) - (input.buttons.contains(.down) ? 1 : 0)
        if digitalX != 0 || digitalY != 0 {
            if digitalY != 0 { return digitalY > 0 ? .up : .down }
            return digitalX > 0 ? .right : .left
        }
        let x = Int(input.leftX), y = Int(input.leftY)
        let candidate: MenuControllerDirection = abs(y) >= abs(x) ? (y >= 0 ? .up : .down) : (x >= 0 ? .right : .left)
        let threshold = candidate == previous ? 11_468 : 18_021
        guard max(abs(x), abs(y)) >= threshold else { return nil }
        return candidate
    }
}

import Foundation

public enum SoftKeyboardInputAction: Equatable, Sendable {
    /// One balanced stroke. The transport owns modifier acquisition/release.
    case key(UInt16, modifiers: UInt8)
    case text(String)
}

/// Plans committed keyboard text before forwarding any part of it. UIKit owns
/// marked-text composition; this helper never receives or retains draft input.
public enum SoftKeyboardTextInput {
    public static func actions(for text: String) -> [SoftKeyboardInputAction]? {
        guard text.utf8.count <= 4096 else { return nil }
        for scalar in text.unicodeScalars where scalar.properties.generalCategory == .control {
            guard [UInt32(0x08), 0x09, 0x0A, 0x0D].contains(scalar.value) else { return nil }
        }
        var actions: [SoftKeyboardInputAction] = []
        var printable = ""
        var previousWasReturn = false
        for scalar in text.unicodeScalars {
            let key: UInt16?
            switch scalar.value {
            case 0x08: key = 0x08
            case 0x09: key = 0x09
            case 0x0A, 0x0D: key = 0x0D
            default: key = nil
            }
            if let key {
                appendPrintable(&printable, to: &actions)
                if scalar.value != 0x0A || !previousWasReturn { actions.append(.key(key, modifiers: 0)) }
            } else {
                printable.unicodeScalars.append(scalar)
            }
            previousWasReturn = scalar.value == 0x0D
        }
        appendPrintable(&printable, to: &actions)
        return actions
    }

    private static func appendPrintable(_ text: inout String, to actions: inout [SoftKeyboardInputAction]) {
        guard !text.isEmpty else { return }
        if text.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) }) {
            // Legacy host key events use the US Win32 layout, matching the
            // established Moonlight/VoidLink soft-keyboard mapping. Unicode
            // commits use UTF-8 rather than splitting graphemes into keys.
            for scalar in text.unicodeScalars { actions.append(asciiStroke(scalar.value)) }
        } else {
            actions.append(.text(text))
        }
        text.removeAll(keepingCapacity: true)
    }

    private static func asciiStroke(_ value: UInt32) -> SoftKeyboardInputAction {
        switch value {
        case 0x61...0x7A: return .key(UInt16(value - 0x20), modifiers: 0)
        case 0x41...0x5A: return .key(UInt16(value), modifiers: 1)
        case 0x30...0x39, 0x20: return .key(UInt16(value), modifiers: 0)
        default:
            let mapping = punctuation[value]!
            return .key(mapping.key, modifiers: mapping.shift ? 1 : 0)
        }
    }

    private static let punctuation: [UInt32: (key: UInt16, shift: Bool)] = [
        0x21: (0x31, true), 0x22: (0xDE, true), 0x23: (0x33, true), 0x24: (0x34, true),
        0x25: (0x35, true), 0x26: (0x37, true), 0x27: (0xDE, false), 0x28: (0x39, true),
        0x29: (0x30, true), 0x2A: (0x38, true), 0x2B: (0xBB, true), 0x2C: (0xBC, false),
        0x2D: (0xBD, false), 0x2E: (0xBE, false), 0x2F: (0xBF, false), 0x3A: (0xBA, true),
        0x3B: (0xBA, false), 0x3C: (0xBC, true), 0x3D: (0xBB, false), 0x3E: (0xBE, true),
        0x3F: (0xBF, true), 0x40: (0x32, true), 0x5B: (0xDB, false), 0x5C: (0xDC, false),
        0x5D: (0xDD, false), 0x5E: (0x36, true), 0x5F: (0xBD, true), 0x60: (0xC0, false),
        0x7B: (0xDB, true), 0x7C: (0xDC, true), 0x7D: (0xDD, true), 0x7E: (0xC0, true)
    ]
}

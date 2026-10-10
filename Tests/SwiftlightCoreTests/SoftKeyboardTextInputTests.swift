import Foundation
import XCTest
@testable import SwiftlightCore

final class SoftKeyboardTextInputTests: XCTestCase {
    func testEmptyCommitDoesNotImplyBackspace() {
        XCTAssertEqual(SoftKeyboardTextInput.actions(for: ""), [])
    }

    func testLettersNumbersAndSpaceUseWindowsVirtualKeysAndShift() {
        XCTAssertEqual(SoftKeyboardTextInput.actions(for: "aAzZ09 "), [
            .key(0x41, modifiers: 0), .key(0x41, modifiers: 1),
            .key(0x5A, modifiers: 0), .key(0x5A, modifiers: 1),
            .key(0x30, modifiers: 0), .key(0x39, modifiers: 0), .key(0x20, modifiers: 0)])
    }

    func testUSKeyboardPunctuationUsesTheCorrectBaseKeysAndShift() {
        // Unshifted/shifted pairs follow the US keyboard's physical key rows.
        let pairs: [(String, UInt16)] = [
            ("1!", 0x31), ("2@", 0x32), ("3#", 0x33), ("4$", 0x34), ("5%", 0x35),
            ("6^", 0x36), ("7&", 0x37), ("8*", 0x38), ("9(", 0x39), ("0)", 0x30),
            ("-_", 0xBD), ("=+", 0xBB), ("[{", 0xDB), ("]}", 0xDD), ("\\|", 0xDC),
            (";:", 0xBA), ("'\"", 0xDE), (",<", 0xBC), (".>", 0xBE), ("/?", 0xBF), ("`~", 0xC0)]
        for (pair, key) in pairs {
            XCTAssertEqual(SoftKeyboardTextInput.actions(for: pair), [
                .key(key, modifiers: 0), .key(key, modifiers: 1)], pair)
        }
    }

    func testEveryPrintableASCIICharacterHasAKeyStroke() throws {
        let text = (0x20...0x7E).map { String(UnicodeScalar($0)!) }.joined()
        let actions = try XCTUnwrap(SoftKeyboardTextInput.actions(for: text))
        XCTAssertEqual(actions.count, 95)
        for action in actions {
            guard case let .key(key, modifiers) = action else { return XCTFail("Printable ASCII must use key strokes") }
            XCTAssertTrue((0x20...0xDE).contains(key))
            XCTAssertTrue(modifiers == 0 || modifiers == 1)
        }
    }

    func testUnicodeRunIsForwardedWholeIncludingASCIIAndGraphemeSequences() {
        for text in ["café", "e\u{301}", "hello 日本語 123", "👩🏽‍💻", "🇺🇸🙂"] {
            XCTAssertEqual(SoftKeyboardTextInput.actions(for: text), [.text(text)])
        }
    }

    func testControlsSplitRunsWithoutSplittingUnicodeOrDuplicatingCRLF() {
        XCTAssertEqual(SoftKeyboardTextInput.actions(for: "A\r\n日本語\t🙂\u{08}z\n"), [
            .key(0x41, modifiers: 1), .key(0x0D, modifiers: 0), .text("日本語"),
            .key(0x09, modifiers: 0), .text("🙂"), .key(0x08, modifiers: 0),
            .key(0x5A, modifiers: 0), .key(0x0D, modifiers: 0)])
        XCTAssertEqual(SoftKeyboardTextInput.actions(for: "\r\r\n\n"), [
            .key(0x0D, modifiers: 0), .key(0x0D, modifiers: 0), .key(0x0D, modifiers: 0)])
    }

    func testForbiddenControlAnywhereRejectsTheWholeCommitBeforeItsPrefix() {
        for value in Array(0x00...0x1F) + Array(0x7F...0x9F) where ![0x08, 0x09, 0x0A, 0x0D].contains(value) {
            let control = String(UnicodeScalar(value)!)
            XCTAssertNil(SoftKeyboardTextInput.actions(for: "valid\n日本語\(control)tail"))
        }
    }

    func testUTF8ByteBoundRejectsOversizeInsteadOfSendingAPrefix() {
        let asciiAtLimit = String(repeating: "a", count: 4096)
        XCTAssertEqual(SoftKeyboardTextInput.actions(for: asciiAtLimit)?.count, 4096)
        XCTAssertNil(SoftKeyboardTextInput.actions(for: asciiAtLimit + "b"))
        let unicodeAtLimit = String(repeating: "🙂", count: 1024)
        XCTAssertEqual(unicodeAtLimit.utf8.count, 4096)
        XCTAssertEqual(SoftKeyboardTextInput.actions(for: unicodeAtLimit), [.text(unicodeAtLimit)])
        XCTAssertNil(SoftKeyboardTextInput.actions(for: unicodeAtLimit + "a"))
        XCTAssertNil(SoftKeyboardTextInput.actions(for: "ok\n" + unicodeAtLimit))
    }
}

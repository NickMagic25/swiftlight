#!/usr/bin/env python3
"""Exercise the production system-keyboard owner in a dedicated simulator app.

The actual UITextField, SwiftUI accessory, and committed-text planner run with a
recording transport. This validates UIKit ownership and composition boundaries;
it does not establish physical keyboard/edge gestures or host input injection.
The dedicated harness bundle is uninstalled after every run.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import selectors
import subprocess
import tempfile
import time


STUBS = r'''
import SwiftUI
import UIKit

enum HostKeyboardShortcut: Equatable { case windows, altTab, altF4, backspace, enter }
private enum RecordedKeyboardInput: Equatable {
    case text(String), stroke(UInt16, UInt8), chord(HostKeyboardShortcut), releaseAll
}
@MainActor final class StreamTransport {
    fileprivate var events: [RecordedKeyboardInput] = []
    var nextResult: Int32 = 0
    func sendText(_ text: String) -> Int32 { events.append(.text(text)); return result() }
    func keyStroke(_ key: UInt16, modifiers: UInt8 = 0) -> Int32 {
        events.append(.stroke(key, modifiers)); return result()
    }
    func keyChord(_ shortcut: HostKeyboardShortcut) -> Int32 { events.append(.chord(shortcut)); return result() }
    func releaseAllInputs() { events.append(.releaseAll) }
    private func result() -> Int32 { let result = nextResult; nextResult = 0; return result }
}
'''


HARNESS = r'''
@MainActor private extension MobileKeyboardAccessoryController {
    var testContent: MobileKeyboardAccessory { host.rootView }
    var testHostedView: UIView { host.view }
}
@MainActor private extension MobileStreamKeyboard {
    var testField: UITextField? { field }
    var testAccessory: UIInputViewController? { field?.keyboardAccessory }
    var testCommitCallback: (() -> Void)? { field?.committed }
    var testAccessorySend: ((HostKeyboardShortcut) -> Void)? {
        (field?.keyboardAccessory as? MobileKeyboardAccessoryController)?.testContent.send
    }
    var testAccessoryDismiss: (() -> Void)? {
        (field?.keyboardAccessory as? MobileKeyboardAccessoryController)?.testContent.dismiss
    }
    var testHasOwners: Bool { field != nil }
    func testCommit(_ text: String) {
        guard let field else { return }
        field.text = Self.sentinel + text
        editingChanged(field)
    }
    func testEditingChanged(_ field: UITextField) { editingChanged(field) }
    func testShortcut(_ shortcut: HostKeyboardShortcut) { send(shortcut) }
}

@MainActor private final class KeyboardHarnessApp: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Keyboard Harness", sessionRole: session.role)
        configuration.delegateClass = KeyboardHarnessScene.self
        return configuration
    }
}
@MainActor private final class KeyboardHarnessScene: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?
    private var checks: [String] = []
    private var rotationFailure: String?
    func scene(_ scene: UIScene, willConnectTo sceneSession: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController(); controller.view.backgroundColor = .black
        let label = UILabel(); label.text = "Swiftlight keyboard validation"; label.textColor = .white
        label.frame = CGRect(x: 24, y: 100, width: 500, height: 44); controller.view.addSubview(label)
        window.rootViewController = controller; window.makeKeyAndVisible(); self.window = window
        Task { @MainActor in await run() }
    }
    private func check(_ value: Bool, _ description: String) {
        if !value { result(status: "FAIL", failure: description); exit(1) }
        checks.append(description)
    }
    private func emit(_ value: String) { FileHandle.standardOutput.write(Data((value + "\n").utf8)) }
    private func result(status: String, failure: String? = nil) {
        var evidence: [String: Any] = ["status": status, "mode": "UIKit-simulator-mobile-system-keyboard",
            "checks": checks, "IMECompositionTested": true, "physicalKeyboardTested": false,
            "edgeGestureTested": false, "hostInputTested": false, "liveVideoTested": false,
            "directPresentationVerified": false]
        if let controller = window?.rootViewController {
            evidence["viewWidth"] = controller.view.bounds.width
            evidence["viewHeight"] = controller.view.bounds.height
            evidence["preferredContentSizeCategory"] = controller.traitCollection.preferredContentSizeCategory.rawValue
        }
        if let failure { evidence["failure"] = failure }
        if let rotationFailure { evidence["rotationUnavailableReason"] = rotationFailure }
        emit("KEYBOARD_RESULT " + String(decoding: try! JSONSerialization.data(withJSONObject: evidence,
            options: [.sortedKeys]), as: UTF8.self))
    }
    private func wait(_ description: String, until condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { check(true, description); return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        check(false, description)
    }
    private func run() async {
        guard let controller = window?.rootViewController else { return }
        if ProcessInfo.processInfo.environment["SWIFTLIGHT_KEYBOARD_LANDSCAPE"] == "1" {
            controller.setNeedsUpdateOfSupportedInterfaceOrientations()
            window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
            await wait("requested compact landscape orientation is active") {
                controller.view.bounds.width > controller.view.bounds.height
            }
        }
        let transport = StreamTransport()
        var canSend = true
        var visibility: [Bool] = []
        var failures: [Int32] = []
        let keyboard = MobileStreamKeyboard(transport: transport, canSend: { canSend },
            visibilityChanged: { visibility.append($0) }, failed: { failures.append($0) })
        let originalSubviewCount = controller.view.subviews.count
        let originalChildCount = controller.children.count
        var accessoryGeometryValid = false
        check(!keyboard.isShowing && !keyboard.testHasOwners, "keyboard starts hidden without field or hosting controller")
        check(transport.events.isEmpty && visibility.isEmpty, "hidden keyboard emits no input or visibility change")
        canSend = false
        check(!keyboard.show(in: controller.view) && !keyboard.testHasOwners,
              "inactive input cannot create keyboard owners")
        canSend = true
        check(!keyboard.show(in: UIView()) && !keyboard.testHasOwners,
              "detached view cannot create keyboard owners")
        check(keyboard.show(in: controller.view), "active stream view can show system keyboard")
        await wait("real UITextField becomes first responder and its accessory attaches to a window") {
            keyboard.testField?.isFirstResponder == true && keyboard.testAccessory?.inputView?.window != nil
        }
        guard let field = keyboard.testField else { check(false, "keyboard field exists"); return }
        check(keyboard.testAccessory?.children.count == 1 &&
              keyboard.testAccessory?.children.first?.parent === keyboard.testAccessory &&
              controller.children.count == originalChildCount,
              "UIKit accessory controller owns the SwiftUI child without reparenting stream content")
        check(field.inputAssistantItem.leadingBarButtonGroups.isEmpty && field.inputAssistantItem.trailingBarButtonGroups.isEmpty,
              "system assistant groups do not obscure the stream accessory")
        check(field.autocorrectionType == .no && field.autocapitalizationType == .none && field.spellCheckingType == .no,
              "remote keyboard disables automatic local corrections")
        check(field.undoManager == nil, "remote field does not alter a shared undo manager")
        let originalAccessory = keyboard.testAccessory.map(ObjectIdentifier.init)
        check(keyboard.show(in: controller.view) &&
              keyboard.testAccessory.map(ObjectIdentifier.init) == originalAccessory && visibility == [true],
              "repeated show does not duplicate field or accessory")
        try? await Task.sleep(for: .seconds(1))
        emit("KEYBOARD_ACCESSORY_LAYOUT " + String(describing: keyboard.testAccessory?.inputView?.bounds))
        if let accessory = keyboard.testAccessory as? MobileKeyboardAccessoryController {
            emit("KEYBOARD_ACCESSORY_SIZING controller=" + String(describing: accessory.view.bounds) +
                " intrinsic=" + String(describing: accessory.inputView?.intrinsicContentSize) +
                " preferred=" + String(describing: accessory.preferredContentSize) +
                " host=" + String(describing: accessory.testHostedView.bounds) +
                " hostIntrinsic=" + String(describing: accessory.testHostedView.intrinsicContentSize) +
                " window=" + String(describing: accessory.inputView?.window?.bounds) +
                " superview=" + String(describing: accessory.view.superview?.bounds) +
                " ancestor=" + String(describing: accessory.view.superview?.superview?.bounds))
            accessoryGeometryValid = abs(accessory.view.bounds.width - controller.view.bounds.width) < 1 &&
                accessory.view.bounds.height >= 56 && accessory.testHostedView.bounds.width > 0
        }
        emit("KEYBOARD_SCREENSHOT_READY")
        try? await Task.sleep(for: .seconds(4))
        if ProcessInfo.processInfo.environment["SWIFTLIGHT_KEYBOARD_ROTATE"] == "1" {
            let landscape = controller.view.bounds.width < controller.view.bounds.height
            window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscapeRight : .portrait)) {
                [weak self] error in
                self?.rotationFailure = error.localizedDescription
                self?.emit("KEYBOARD_GEOMETRY_ERROR " + error.localizedDescription)
            }
            for _ in 0..<100 {
                if rotationFailure != nil || (controller.view.bounds.width > controller.view.bounds.height) == landscape { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            emit("KEYBOARD_ROTATION_STATE view=" + String(describing: controller.view.bounds) +
                 " window=" + String(describing: window?.bounds) +
                 " responder=" + String(describing: field.isFirstResponder) +
                 " showing=" + String(describing: keyboard.isShowing) +
                 " owners=" + String(describing: keyboard.testHasOwners))
            check(keyboard.isShowing && keyboard.testHasOwners, "geometry request preserves current first responder and owners")
            if rotationFailure != nil {
                let content = MobileKeyboardAccessory(send: { _ in }, dismiss: {})
                let resizeController = MobileKeyboardAccessoryController(content: content, width: 360)
                let container = UIView(frame: CGRect(x: 0, y: 100, width: 360, height: 200))
                container.isHidden = true
                controller.addChild(resizeController); controller.view.addSubview(container)
                container.addSubview(resizeController.view); resizeController.didMove(toParent: controller)
                container.layoutIfNeeded(); resizeController.view.layoutIfNeeded()
                check(abs(resizeController.view.bounds.width - 360) < 1,
                      "standalone production accessory adopts a compact UIKit container")
                container.frame.size.width = 680
                container.layoutIfNeeded(); resizeController.view.layoutIfNeeded()
                check(abs(resizeController.view.bounds.width - 680) < 1 && resizeController.testHostedView.bounds.width > 0,
                      "standalone production accessory adapts when its UIKit container resizes")
                resizeController.willMove(toParent: nil); resizeController.view.removeFromSuperview()
                resizeController.removeFromParent(); container.removeFromSuperview()
            } else {
                check((controller.view.bounds.width > controller.view.bounds.height) == landscape,
                      "requested scene rotation completes")
                try? await Task.sleep(for: .seconds(1))
                guard let accessory = keyboard.testAccessory as? MobileKeyboardAccessoryController else {
                    check(false, "accessory survives scene rotation"); return
                }
                check(abs(accessory.view.bounds.width - controller.view.bounds.width) < 1 &&
                      accessory.testHostedView.bounds.width > 0,
                      "shown accessory resizes to the rotated keyboard container")
                emit("KEYBOARD_ROTATED_LAYOUT " + String(describing: accessory.view.bounds))
                emit("KEYBOARD_SCREENSHOT_READY_ROTATED")
                try? await Task.sleep(for: .seconds(4))
            }
        }

        keyboard.testCommit("aA!")
        check(transport.events == [.stroke(0x41, 0), .stroke(0x41, 1), .stroke(0x31, 1)],
              "committed ASCII uses complete virtual-key strokes with Shift")
        transport.events = []
        keyboard.testCommit("café 👩🏽‍💻")
        check(transport.events == [.text("café 👩🏽‍💻")], "Unicode grapheme run is forwarded in one UTF-8 call")
        transport.events = []
        keyboard.testCommit("日本語\t🙂\u{08}")
        check(transport.events == [.text("日本語"),
              .stroke(0x09, 0), .text("🙂"), .stroke(0x08, 0)],
              "committed single-line text preserves Unicode while splitting Tab and Backspace")
        transport.events = []
        check(!keyboard.textFieldShouldReturn(field) && transport.events == [.stroke(0x0D, 0)],
              "Return sends one remote Enter and keeps system keyboard open")
        transport.events = []
        field.deleteBackward(); field.sendActions(for: .editingChanged)
        check(transport.events == [.stroke(0x08, 0)], "backspace at empty remote input sends one Backspace stroke")

        transport.events = []
        field.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
        check(field.markedTextRange != nil, "UIKit creates an actual marked-text composition")
        field.sendActions(for: .editingChanged)
        check(transport.events.isEmpty, "marked IME text never reaches transport")
        check(!keyboard.textFieldShouldReturn(field) && transport.events.isEmpty,
              "Return during composition does not send a remote Enter")
        field.unmarkText()
        check(field.markedTextRange == nil && transport.events == [.text("に")],
              "unmarkText forwards only the final committed Unicode candidate")
        field.sendActions(for: .editingChanged)
        check(transport.events == [.text("に")], "subsequent editingChanged cannot duplicate an IME commit")

        transport.events = []
        field.setMarkedText(String(repeating: "に", count: 1000), selectedRange: NSRange(location: 1000, length: 0))
        guard let marked = field.markedTextRange else { check(false, "large marked composition exists"); return }
        let range = NSRange(location: field.offset(from: field.beginningOfDocument, to: marked.start),
                            length: field.offset(from: marked.start, to: marked.end))
        let replacement = String(repeating: "ほ", count: 1000)
        check(keyboard.textField(field, shouldChangeCharactersIn: range, replacementString: replacement),
              "bounded IME replacement is validated after subtracting replaced text")
        field.setMarkedText(replacement, selectedRange: NSRange(location: 1000, length: 0))
        field.sendActions(for: .editingChanged)
        check(transport.events.isEmpty, "large replacement remains unsent while marked")
        field.unmarkText()
        check(transport.events == [.text(replacement)], "large bounded candidate commits once")

        transport.events = []
        keyboard.testAccessorySend?(.windows); keyboard.testAccessorySend?(.altTab); keyboard.testAccessorySend?(.altF4)
        check(transport.events == [.chord(.windows), .chord(.altTab), .chord(.altF4)],
              "accessory action closures send distinct atomic Windows, Alt-Tab and Alt-F4 chords")
        transport.events = []
        let retiredCallback = keyboard.testCommitCallback
        let retiredSend = keyboard.testAccessorySend
        let retiredDismiss = keyboard.testAccessoryDismiss
        canSend = false
        keyboard.testCommit("blocked"); keyboard.testShortcut(.altF4)
        check(!keyboard.textFieldShouldReturn(field) && transport.events == [.releaseAll],
              "capture loss rejects text, Return and accessory actions and releases held input")
        keyboard.hide()
        check(!keyboard.isShowing && !keyboard.testHasOwners && field.superview == nil &&
              (field.text ?? "").isEmpty && field.inputAccessoryViewController == nil,
              "hide retires and removes the field and its composed text")
        check(controller.children.count == originalChildCount && controller.view.subviews.count == originalSubviewCount,
              "hide removes temporary accessory controller and view hierarchy")
        check(transport.events == [.releaseAll] && visibility == [true, false],
              "hide requests held-input cleanup and publishes visibility once")
        transport.events = []
        field.text = "late"; field.sendActions(for: .editingChanged); retiredCallback?()
        keyboard.testEditingChanged(field)
        check(!keyboard.textFieldShouldReturn(field) && transport.events.isEmpty,
              "retired field callbacks cannot send text or keys")
        keyboard.hide()
        check(transport.events.isEmpty && visibility == [true, false], "repeated hide does not repeat input cleanup")

        canSend = true
        check(keyboard.show(in: controller.view), "fresh keyboard can be shown after suspension")
        await wait("fresh field owns first responder after suspension") { keyboard.isShowing }
        transport.events = []
        retiredCallback?(); retiredSend?(.altF4); retiredDismiss?()
        check(keyboard.isShowing && transport.events.isEmpty,
              "retired commit and accessory closures cannot send to or dismiss a fresh keyboard")
        keyboard.testCommit("valid\u{0}tail")
        check(failures == [-4] && transport.events == [.releaseAll] && !keyboard.testHasOwners,
              "invalid commit sends no prefix, reports failure and removes keyboard")
        check(keyboard.show(in: controller.view), "keyboard can be reopened after invalid input")
        transport.events = []; transport.nextResult = -2
        keyboard.testCommit("abc")
        check(failures == [-4, -2] && transport.events == [.stroke(0x41, 0), .releaseAll] && !keyboard.testHasOwners,
              "transport failure stops a multi-stroke commit and cleans up keyboard")
        check(keyboard.show(in: controller.view), "keyboard can be reopened after transport denial")
        transport.events = []
        guard let finalField = keyboard.testField else { check(false, "final keyboard field exists"); return }
        check(!keyboard.textField(finalField, shouldChangeCharactersIn: NSRange(location: 0, length: 0),
                                 replacementString: String(repeating: "x", count: 4097)),
              "oversized paste is rejected before entering the local composing buffer")
        check(failures == [-4, -2, -4] && transport.events == [.releaseAll] && !keyboard.testHasOwners,
              "oversized paste cleanup sends no remote prefix")
        check(keyboard.show(in: controller.view), "keyboard can be reopened after oversized paste")
        transport.events = []
        keyboard.testAccessoryDismiss?()
        check(!keyboard.isShowing && !keyboard.testHasOwners && transport.events == [.releaseAll],
              "current SwiftUI Hide callback removes keyboard and releases held input")
        check(accessoryGeometryValid,
              "settled accessory spans the screen and gives SwiftUI nonzero layout space")
        result(status: "PASS"); exit(0)
    }
}
@main private struct KeyboardHarness {
    @MainActor static func main() {
        UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(KeyboardHarnessApp.self))
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("simulator", help="Booted iPhone or iPad simulator UDID")
    parser.add_argument("--screenshot", type=Path, help="Optional local screenshot of system keyboard and accessory")
    parser.add_argument("--landscape", action="store_true", help="Request a compact landscape keyboard layout")
    parser.add_argument("--large-text", action="store_true", help="Temporarily use the largest accessibility text size")
    parser.add_argument("--rotate-while-shown", action="store_true", help="Rotate the scene while the keyboard is open")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    paths = ["Sources/shared/SwiftlightCore/SoftKeyboardTextInput.swift", "Sources/mobile/MobileStreamKeyboard.swift"]
    inputs = {path: (root / path).read_text() for path in paths}
    adapter = inputs[paths[-1]].replace("import SwiftlightCore\n", "").replace("import SwiftlightTransport\n", "")
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
    architecture = subprocess.check_output(["uname", "-m"], text=True).strip()
    bundle_id = "org.swiftlight.mobile-keyboard-harness"
    with tempfile.TemporaryDirectory(prefix="swiftlight-mobile-keyboard-") as temporary:
        directory = Path(temporary); app = directory / "KeyboardHarness.app"; app.mkdir()
        combined = directory / "KeyboardHarness.swift"
        combined.write_text(STUBS + inputs[paths[0]] + adapter + HARNESS)
        cache = root / ".build/mobile-keyboard-module-cache"; cache.mkdir(parents=True, exist_ok=True)
        subprocess.run(["xcrun", "--sdk", "iphonesimulator", "swiftc", "-swift-version", "6", "-parse-as-library",
                        "-target", f"{architecture}-apple-ios26.0-simulator", "-sdk", sdk,
                        "-module-cache-path", str(cache), str(combined), "-o", str(app / "KeyboardHarness")],
                       check=True, timeout=120)
        info = {"CFBundleIdentifier": bundle_id, "CFBundleExecutable": "KeyboardHarness", "CFBundleName": "Keyboard Harness",
                "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0", "CFBundlePackageType": "APPL",
                "LSRequiresIPhoneOS": True, "UIDeviceFamily": [1, 2], "UILaunchScreen": {},
                "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False,
                    "UISceneConfigurations": {"UIWindowSceneSessionRoleApplication": [
                        {"UISceneConfigurationName": "Keyboard Harness"}]}},
                "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
                    "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"]}
        (app / "Info.plist").write_bytes(plistlib.dumps(info))
        subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, timeout=30)
        subprocess.run(["xcrun", "simctl", "install", args.simulator, str(app)], check=True, timeout=30)
        original_text_size = None
        try:
            if args.large_text:
                original_text_size = subprocess.check_output(
                    ["xcrun", "simctl", "ui", args.simulator, "content_size"], text=True).strip()
                subprocess.run(["xcrun", "simctl", "ui", args.simulator, "content_size",
                                "accessibility-extra-extra-extra-large"], check=True, timeout=30)
            environment = os.environ.copy()
            if args.landscape: environment["SIMCTL_CHILD_SWIFTLIGHT_KEYBOARD_LANDSCAPE"] = "1"
            if args.rotate_while_shown: environment["SIMCTL_CHILD_SWIFTLIGHT_KEYBOARD_ROTATE"] = "1"
            process = subprocess.Popen(["xcrun", "simctl", "launch", "--terminate-running-process", "--console",
                                        args.simulator, bundle_id], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                       bufsize=0, env=environment)
            marker = None
            pending = b""
            deadline = time.monotonic() + 60
            selector = selectors.DefaultSelector(); selector.register(process.stdout, selectors.EVENT_READ)
            while time.monotonic() < deadline:
                if not selector.select(timeout=0.5):
                    if process.poll() is not None: break
                    continue
                chunk = os.read(process.stdout.fileno(), 4096)
                if not chunk:
                    if process.poll() is not None: break
                    continue
                pending += chunk
                lines = pending.split(b"\n"); pending = lines.pop()
                for raw_line in lines:
                    line = raw_line.decode(errors="replace")
                    print(line, flush=True)
                    if "KEYBOARD_SCREENSHOT_READY" in line and args.screenshot:
                        screenshot = args.screenshot
                        if "KEYBOARD_SCREENSHOT_READY_ROTATED" in line:
                            screenshot = screenshot.with_stem(screenshot.stem + "-rotated")
                        screenshot.parent.mkdir(parents=True, exist_ok=True)
                        subprocess.run(["xcrun", "simctl", "io", args.simulator, "screenshot", str(screenshot)],
                                       check=True, timeout=30)
                    if "KEYBOARD_RESULT " in line:
                        marker = line.split("KEYBOARD_RESULT ", 1)[1]
                if marker is not None:
                    break
            if marker is None:
                process.terminate(); process.wait(timeout=10)
                print("FAIL: simulator did not return keyboard evidence within 60 seconds")
                return 1
            process.wait(timeout=10)
            evidence = json.loads(marker)
            evidence["sourceSHA256"] = {path: hashlib.sha256(value.encode()).hexdigest() for path, value in inputs.items()}
            evidence["harnessSHA256"] = hashlib.sha256(combined.read_bytes()).hexdigest()
            evidence["simulator"] = args.simulator
            if args.screenshot: evidence["screenshot"] = str(args.screenshot.resolve())
            print(json.dumps(evidence, indent=2, sort_keys=True))
            return 0 if evidence["status"] == "PASS" else 1
        finally:
            if original_text_size and original_text_size not in {"unknown", "unsupported"}:
                subprocess.run(["xcrun", "simctl", "ui", args.simulator, "content_size", original_text_size],
                               check=False, timeout=30)
            subprocess.run(["xcrun", "simctl", "uninstall", args.simulator, bundle_id], check=False, timeout=30)


if __name__ == "__main__":
    raise SystemExit(main())

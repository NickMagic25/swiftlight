#!/usr/bin/env python3
"""Exercise the production mobile touch adapter in a dedicated UIKit simulator app.

Synthetic UITouch objects drive actual adapter and Core state code. The recording
transport is a test double: these checks do not establish physical gesture
delivery, host input injection, live streaming, or presentation performance.
The dedicated harness bundle is removed after every simulator run.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile


STUBS = r'''
import UIKit

enum NativeTouchAvailability { case supported, unsupported, denied, notStreaming }
enum TouchEventPhase: Equatable { case down, move, up, cancel }
private enum RecordedInput: Equatable {
    case move(Int16, Int16), button(Int, Bool), scroll(Int16, Int16)
    case native(TouchEventPhase, UInt32, Float, Float), releaseAll
}
@MainActor final class StreamTransport {
    var nativeTouchAvailability = NativeTouchAvailability.supported
    fileprivate var events: [RecordedInput] = []
    fileprivate var held: Set<UInt32> = []
    var nextTouchResult: Int32 = 0
    func mouseMove(dx: Int16, dy: Int16) { events.append(.move(dx, dy)) }
    func mouseButton(_ button: Int, pressed: Bool) { events.append(.button(button, pressed)) }
    func scroll(vertical: Int16, horizontal: Int16 = 0) { events.append(.scroll(vertical, horizontal)) }
    func touch(event: TouchEventPhase, id: UInt32, x: Float, y: Float, pressure: Float = 0) -> Int32 {
        events.append(.native(event, id, x, y))
        let result = nextTouchResult; nextTouchResult = 0
        if result == 0 {
            if event == .down { held.insert(id) }
            if event == .up || event == .cancel { held.remove(id) }
        }
        return result
    }
    func releaseAllInputs() { events.append(.releaseAll); held.removeAll() }
}
@MainActor private final class SyntheticTouch: UITouch {
    var point: CGPoint
    var time: TimeInterval
    var kind: UITouch.TouchType = .direct
    init(_ x: CGFloat, _ y: CGFloat, _ timestamp: TimeInterval) {
        point = CGPoint(x: x, y: y); time = timestamp; super.init()
    }
    override var timestamp: TimeInterval { time }
    override var type: UITouch.TouchType { kind }
    override func location(in view: UIView?) -> CGPoint { point }
    func move(_ x: CGFloat, _ y: CGFloat, at timestamp: TimeInterval) {
        point = CGPoint(x: x, y: y); time = timestamp
    }
}
'''


HARNESS = r'''
@MainActor private final class TouchHarnessApp: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Touch Input Harness", sessionRole: session.role)
        configuration.delegateClass = TouchHarnessScene.self
        return configuration
    }
}
@MainActor private final class TouchHarnessScene: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?
    private var checks: [String] = []
    func scene(_ scene: UIScene, willConnectTo sceneSession: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController(); controller.view.backgroundColor = .black
        window.rootViewController = controller; window.makeKeyAndVisible(); self.window = window
        Task { @MainActor in run() }
    }
    private func check(_ value: Bool, _ description: String) {
        if !value { result(status: "FAIL", failure: description); exit(1) }
        checks.append(description)
    }
    private func result(status: String, failure: String? = nil) {
        var evidence: [String: Any] = ["status": status, "mode": "UIKit-simulator-mobile-touch-routing",
            "checks": checks, "physicalGesturesTested": false, "hostInputTested": false,
            "liveVideoTested": false, "directPresentationVerified": false]
        if let failure { evidence["failure"] = failure }
        print("TOUCH_INPUT_RESULT " + String(decoding: try! JSONSerialization.data(withJSONObject: evidence,
            options: [.sortedKeys]), as: UTF8.self))
    }
    private func run() {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        window!.rootViewController!.view.addSubview(view)
        let geometry = NativeTouchGeometry(frameSize: CGSize(width: 1000, height: 800),
            contentRect: CGRect(x: 100, y: 100, width: 800, height: 600), viewBounds: view.bounds,
            drawableSize: CGSize(width: 800, height: 800), scaling: .fit)

        let transport = StreamTransport()
        var issues: [MobileTouchInputIssue] = []
        let trackpad = MobileTouchInput(mode: .trackpad, transport: transport) { issues.append($0) }
        let finger = SyntheticTouch(100, 100, 1)
        trackpad.consume([finger], phase: .began, in: view, geometry: geometry)
        finger.time = 1.1; trackpad.consume([finger], phase: .ended, in: view, geometry: geometry)
        check(transport.events == [.button(1, true), .button(1, false)], "trackpad tap sends one left click")
        transport.events = []
        finger.time = 1.2; trackpad.consume([finger], phase: .began, in: view, geometry: geometry)
        finger.move(120, 110, at: 1.25); trackpad.consume([finger], phase: .moved, in: view, geometry: geometry)
        finger.time = 1.3; trackpad.consume([finger], phase: .ended, in: view, geometry: geometry)
        check(transport.events == [.button(1, true), .move(20, 10), .button(1, false)],
              "double tap drag holds left button through movement and releases on lift")

        trackpad.cancel(); transport.events = []
        finger.move(100, 100, at: 2); trackpad.consume([finger], phase: .began, in: view, geometry: geometry)
        finger.time = 2.1; trackpad.consume([finger], phase: .ended, in: view, geometry: geometry)
        transport.events = []
        finger.time = 2.2; trackpad.consume([finger], phase: .began, in: view, geometry: geometry)
        trackpad.consume([finger], phase: .cancelled, in: view, geometry: geometry)
        check(transport.events == [.button(1, true), .button(1, false)], "cancellation releases an admitted drag")
        transport.events = []
        finger.move(200, 200, at: 2.3); trackpad.consume([finger], phase: .moved, in: view, geometry: geometry)
        trackpad.consume([finger], phase: .ended, in: view, geometry: geometry)
        check(transport.events.isEmpty, "late touch events cannot revive a cancelled drag")
        let fresh = SyntheticTouch(100, 100, 2.5)
        trackpad.consume([fresh], phase: .began, in: view, geometry: geometry)
        fresh.time = 2.6; trackpad.consume([fresh], phase: .ended, in: view, geometry: geometry)
        transport.events = []
        fresh.time = 2.7; trackpad.consume([fresh], phase: .began, in: view, geometry: geometry)
        trackpad.consume([finger], phase: .cancelled, in: view, geometry: geometry)
        check(transport.events == [.button(1, true)], "stale unknown UIKit cancellation cannot cancel a fresh drag")
        fresh.time = 2.8; trackpad.consume([fresh], phase: .ended, in: view, geometry: geometry)
        check(transport.events == [.button(1, true), .button(1, false)], "fresh drag still completes after stale cancellation")
        trackpad.cancel(); transport.events = []

        let second = SyntheticTouch(200, 100, 3)
        finger.move(100, 100, at: 3)
        trackpad.consume([finger, second], phase: .began, in: view, geometry: geometry)
        finger.time = 3.1; second.time = 3.1
        trackpad.consume([finger, second], phase: .ended, in: view, geometry: geometry)
        check(transport.events == [.button(3, true), .button(3, false)], "two-finger tap sends one right click")
        transport.events = []
        finger.time = 4; second.time = 4
        trackpad.consume([finger, second], phase: .began, in: view, geometry: geometry)
        finger.move(110, 130, at: 4.1); second.move(210, 130, at: 4.1)
        trackpad.consume([finger, second], phase: .moved, in: view, geometry: geometry)
        finger.time = 4.2; second.time = 4.2
        trackpad.consume([finger, second], phase: .ended, in: view, geometry: geometry)
        check(transport.events == [.scroll(210, -70)], "two-finger movement scrolls without moving or clicking pointer")

        transport.events = []
        let third = SyntheticTouch(300, 100, 5)
        finger.time = 5; second.time = 5
        trackpad.consume([finger, second, third], phase: .began, in: view, geometry: geometry)
        finger.move(300, 300, at: 5.1)
        trackpad.consume([finger], phase: .moved, in: view, geometry: geometry)
        trackpad.consume([second, third], phase: .ended, in: view, geometry: geometry)
        trackpad.consume([finger], phase: .ended, in: view, geometry: geometry)
        check(transport.events.isEmpty, "three-finger local shortcut suppresses the entire trackpad interaction")
        let edge = SyntheticTouch(24, 100, 6)
        trackpad.consume([edge], phase: .began, in: view, geometry: geometry)
        edge.move(300, 100, at: 6.1); trackpad.consume([edge], phase: .moved, in: view, geometry: geometry)
        trackpad.consume([edge], phase: .ended, in: view, geometry: geometry)
        check(transport.events.isEmpty, "left-edge disconnect region never starts remote trackpad input")
        edge.move(10, 100, at: 7); finger.move(100, 100, at: 7); second.move(200, 100, at: 7)
        trackpad.consume([edge, finger, second], phase: .began, in: view, geometry: geometry)
        finger.move(200, 200, at: 7.1); second.move(300, 200, at: 7.1)
        trackpad.consume([finger, second], phase: .moved, in: view, geometry: geometry)
        trackpad.consume([finger, second], phase: .ended, in: view, geometry: geometry)
        trackpad.consume([edge], phase: .ended, in: view, geometry: geometry)
        check(transport.events.isEmpty, "three physical fingers including left edge cannot become a two-finger trackpad gesture")

        let nativeTransport = StreamTransport()
        let native = MobileTouchInput(mode: .nativeTouch, transport: nativeTransport) { issues.append($0) }
        let left = SyntheticTouch(100, 100, 10), right = SyntheticTouch(300, 300, 10)
        native.consume([left, right], phase: .began, in: view, geometry: geometry)
        let downs = nativeTransport.events.compactMap { event -> (UInt32, Float, Float)? in
            if case let .native(.down, id, x, y) = event { return (id, x, y) }; return nil
        }
        check(downs.count == 2 && Set(downs.map { $0.0 }).count == 2,
              "native contacts receive distinct stable wire IDs")
        guard let leftDown = downs.first(where: { $0.1 == 0.3 }),
              let rightDown = downs.first(where: { $0.1 == 0.7 }) else {
            check(false, "native downs map the full-frame aperture"); return
        }
        check(leftDown.2 == 0.25 && rightDown.2 == 0.75, "native downs map full-frame aperture coordinates")
        nativeTransport.events = []
        left.move(-100, -100, at: 10.1); native.consume([left], phase: .moved, in: view, geometry: geometry)
        check(nativeTransport.events == [.native(.move, leftDown.0, 0.1, 0.125)],
              "held native contact clamps outside visible video while preserving its ID")
        nativeTransport.events = []
        right.time = 10.2; native.consume([right], phase: .ended, in: view, geometry: geometry)
        check(nativeTransport.events == [.native(.up, rightDown.0, 0.7, 0.75)], "native lift completes its original contact")
        nativeTransport.events = []
        native.cancel()
        check(nativeTransport.events == [.native(.cancel, leftDown.0, 0.1, 0.125)] && nativeTransport.held.isEmpty,
              "native cancellation completes every remaining contact")
        nativeTransport.events = []
        native.consume([left], phase: .moved, in: view, geometry: geometry)
        native.consume([left], phase: .ended, in: view, geometry: geometry)
        check(nativeTransport.events.isEmpty, "late native motion cannot revive cancelled contacts")

        let bar = SyntheticTouch(100, 10, 11)
        native.consume([bar], phase: .began, in: view, geometry: geometry)
        bar.move(100, 100, at: 11.1); native.consume([bar], phase: .moved, in: view, geometry: geometry)
        native.consume([bar], phase: .ended, in: view, geometry: geometry)
        edge.move(24, 100, at: 11.2)
        native.consume([edge], phase: .began, in: view, geometry: geometry)
        native.consume([edge], phase: .ended, in: view, geometry: geometry)
        check(nativeTransport.events.isEmpty, "native letterbox and left-edge downs cannot acquire remote contacts")
        left.move(100, 100, at: 12); right.time = 12
        native.consume([left, right], phase: .began, in: view, geometry: geometry)
        nativeTransport.events = []
        third.time = 12.1; native.consume([third], phase: .began, in: view, geometry: geometry)
        check(nativeTransport.events.count == 2 && nativeTransport.held.isEmpty &&
              nativeTransport.events.allSatisfy { if case .native(.cancel, _, _, _) = $0 { true } else { false } },
              "third local finger cancels native contacts before local shortcut")
        nativeTransport.events = []
        native.consume([right, third], phase: .ended, in: view, geometry: geometry)
        native.consume([left], phase: .moved, in: view, geometry: geometry)
        native.consume([left], phase: .ended, in: view, geometry: geometry)
        check(nativeTransport.events.isEmpty, "remaining native fingers stay suppressed until all local fingers lift")
        edge.move(10, 100, at: 13); left.move(100, 100, at: 13); right.move(300, 300, at: 13)
        native.consume([edge, left, right], phase: .began, in: view, geometry: geometry)
        left.move(200, 200, at: 13.1); native.consume([left], phase: .moved, in: view, geometry: geometry)
        native.consume([left, right], phase: .ended, in: view, geometry: geometry)
        native.consume([edge], phase: .ended, in: view, geometry: geometry)
        check(nativeTransport.events.isEmpty, "three physical fingers including left edge cannot start native contacts")

        let unsupportedTransport = StreamTransport(); unsupportedTransport.nativeTouchAvailability = .unsupported
        var unsupportedIssues: [MobileTouchInputIssue] = []
        let unsupported = MobileTouchInput(mode: .nativeTouch, transport: unsupportedTransport) { unsupportedIssues.append($0) }
        finger.move(100, 100, at: 20)
        unsupported.consume([finger], phase: .began, in: view, geometry: geometry)
        unsupported.consume([finger], phase: .ended, in: view, geometry: geometry)
        check(unsupportedIssues == [.unsupported] && unsupportedTransport.events.isEmpty,
              "unsupported native host reports once and discards the notice-opening interaction")
        finger.time = 21; unsupported.consume([finger], phase: .began, in: view, geometry: geometry)
        finger.time = 21.1; unsupported.consume([finger], phase: .ended, in: view, geometry: geometry)
        check(unsupportedIssues == [.unsupported] && unsupportedTransport.events == [.button(1, true), .button(1, false)],
              "unsupported native host uses trackpad on the next interaction without repeated notices")

        let deniedTransport = StreamTransport(); deniedTransport.nativeTouchAvailability = .denied
        var deniedIssues: [MobileTouchInputIssue] = []
        let denied = MobileTouchInput(mode: .nativeTouch, transport: deniedTransport) { deniedIssues.append($0) }
        for timestamp in [22.0, 23.0] {
            finger.time = timestamp; denied.consume([finger], phase: .began, in: view, geometry: geometry)
            finger.move(200, 200, at: timestamp + 0.1)
            denied.consume([finger], phase: .moved, in: view, geometry: geometry)
            denied.consume([finger], phase: .ended, in: view, geometry: geometry)
        }
        check(deniedIssues == [.denied] && deniedTransport.events.isEmpty,
              "permission-denied native input never falls back to mouse events")

        let failedTransport = StreamTransport()
        var failureIssues: [MobileTouchInputIssue] = []
        let failed = MobileTouchInput(mode: .nativeTouch, transport: failedTransport) { failureIssues.append($0) }
        finger.move(100, 100, at: 30); failed.consume([finger], phase: .began, in: view, geometry: geometry)
        check(failedTransport.held.count == 1, "failure probe owns a successfully admitted native contact")
        failedTransport.events = []; failedTransport.nextTouchResult = -1
        finger.move(110, 110, at: 30.1); failed.consume([finger], phase: .moved, in: view, geometry: geometry)
        check(failureIssues == [.failed] && failedTransport.events.count == 2 &&
              failedTransport.events.last == .releaseAll && failedTransport.held.isEmpty,
              "native send failure requests cancel-all cleanup and reports failure")
        failedTransport.events = []
        finger.time = 30.2; failed.consume([finger], phase: .moved, in: view, geometry: geometry)
        failed.consume([finger], phase: .ended, in: view, geometry: geometry)
        check(failedTransport.events.isEmpty, "late events after send failure cannot recreate native input")
        check(issues.isEmpty, "supported trackpad and native interactions emit no capability notices")
        result(status: "PASS"); exit(0)
    }
}
@main private struct TouchHarness {
    @MainActor static func main() {
        UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(TouchHarnessApp.self))
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("simulator", help="Booted iPhone or iPad simulator UDID")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    paths = ["Sources/shared/SwiftlightCore/StreamSettings.swift", "Sources/shared/SwiftlightCore/DisplayGeometry.swift",
             "Sources/shared/SwiftlightCore/TrackpadInput.swift", "Sources/shared/SwiftlightCore/NativeTouchInputState.swift",
             "Sources/mobile/MobileTouchInput.swift"]
    inputs = {path: (root / path).read_text() for path in paths}
    adapter = inputs[paths[-1]].replace("import SwiftlightCore\n", "").replace("import SwiftlightTransport\n", "")
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
    architecture = subprocess.check_output(["uname", "-m"], text=True).strip()
    bundle_id = "org.swiftlight.mobile-touch-input-harness"
    with tempfile.TemporaryDirectory(prefix="swiftlight-mobile-touch-") as temporary:
        directory = Path(temporary); app = directory / "TouchHarness.app"; app.mkdir()
        combined = directory / "TouchHarness.swift"
        combined.write_text(STUBS + "\n".join(inputs[path] for path in paths[:-1]) + adapter + HARNESS)
        cache = root / ".build/mobile-touch-module-cache"; cache.mkdir(parents=True, exist_ok=True)
        subprocess.run(["xcrun", "--sdk", "iphonesimulator", "swiftc", "-swift-version", "6", "-parse-as-library",
                        "-target", f"{architecture}-apple-ios26.0-simulator", "-sdk", sdk,
                        "-module-cache-path", str(cache), str(combined), "-o", str(app / "TouchHarness")],
                       check=True, timeout=120)
        info = {"CFBundleIdentifier": bundle_id, "CFBundleExecutable": "TouchHarness", "CFBundleName": "Touch Input Harness",
                "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0", "CFBundlePackageType": "APPL",
                "LSRequiresIPhoneOS": True, "UIDeviceFamily": [1, 2], "UILaunchScreen": {},
                "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False,
                    "UISceneConfigurations": {"UIWindowSceneSessionRoleApplication": [
                        {"UISceneConfigurationName": "Touch Input Harness"}]}},
                "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
                    "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"]}
        (app / "Info.plist").write_bytes(plistlib.dumps(info))
        subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, timeout=30)
        subprocess.run(["xcrun", "simctl", "install", args.simulator, str(app)], check=True, timeout=30)
        try:
            run = subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process", "--console",
                                  args.simulator, bundle_id], capture_output=True, text=True, timeout=60)
            print(run.stdout, end="")
            if run.stderr: print(run.stderr, end="")
            marker = next((line.split("TOUCH_INPUT_RESULT ", 1)[1] for line in run.stdout.splitlines()
                           if "TOUCH_INPUT_RESULT " in line), None)
            if marker is None: return run.returncode or 1
            evidence = json.loads(marker)
            evidence["sourceSHA256"] = {path: hashlib.sha256(value.encode()).hexdigest() for path, value in inputs.items()}
            evidence["harnessSHA256"] = hashlib.sha256(combined.read_bytes()).hexdigest()
            evidence["simulator"] = args.simulator
            print(json.dumps(evidence, indent=2, sort_keys=True))
            return 0 if evidence["status"] == "PASS" else 1
        except subprocess.TimeoutExpired as error:
            for output in (error.stdout, error.stderr):
                if output: print(output.decode(errors="replace") if isinstance(output, bytes) else output, end="")
            print("FAIL: simulator launch did not complete within 60 seconds")
            return 1
        finally:
            subprocess.run(["xcrun", "simctl", "uninstall", args.simulator, bundle_id], check=False, timeout=30)


if __name__ == "__main__":
    raise SystemExit(main())

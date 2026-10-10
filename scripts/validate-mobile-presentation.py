#!/usr/bin/env python3
"""Exercise the production mobile presenter in UIKit with a fake stream owner.

This simulator app validates presentation lifetime, SwiftUI/native observation,
and local exit admission only. It does not decode video or establish HDR
correctness, Direct mode, or live latency. Observation mode drives published
session changes through the production SwiftUI adapter without manual updates.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile


STUBS = r'''
import Combine
import GameController
import Metal
import QuartzCore
import SwiftUI
import UIKit

@MainActor private final class HarnessPipeline { let id: Int; init(_ id: Int) { self.id = id } }
@MainActor private final class HarnessTransport {
    private(set) var releaseCount = 0
    func releaseAllInputs() { releaseCount += 1 }
}
private struct HarnessSettings {}
private struct HarnessStatisticsPreferences { var position = 0 }
@MainActor private final class MobileStreamingSession: ObservableObject {
    @Published var isActive = false
    @Published var hasVideo = false
    @Published var status = "Connecting"
    @Published var controlsVisible = false
    var presentationGeneration: UInt64 = 0
    @Published var pipeline: HarnessPipeline?
    var transport: HarnessTransport?
    var settings = HarnessSettings()
    @Published var inputEnabled = false
    @Published var showingStatistics = false
    @Published var statisticsRows: [String] = []
    @Published var statisticsPreferences = HarnessStatisticsPreferences()
    private(set) var disconnectBegan = false
    private(set) var teardownCompleted = false
    func releaseInputs() {}
    func toggleStatistics() { showingStatistics.toggle() }
    func setControlsVisible(_ visible: Bool) { controlsVisible = visible }
    func disconnect() async {
        disconnectBegan = true; presentationGeneration &+= 1; isActive = false
        // Native dismissal must not wait for a blocking transport teardown.
        try? await Task.sleep(for: .seconds(2))
        pipeline = nil; transport = nil; teardownCompleted = true
    }
}
private struct MobileStreamControls: View {
    @ObservedObject var session: MobileStreamingSession
    let generation: UInt64
    var body: some View { Text("Stream Controls") }
}
@MainActor private final class MobileStreamView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    let pipeline: HarnessPipeline
    private let transport: HarnessTransport
    private let disconnect: () -> Void
    private var lastTouch: CGPoint?
    var inputEnabled = false
    private(set) var statisticsVisible = false
    private(set) var statisticsRows: [String] = []
    private(set) var stopped = false
    init(pipeline: HarnessPipeline, transport: HarnessTransport, settings: HarnessSettings,
         toggleStatistics: @escaping () -> Void, disconnect: @escaping () -> Void, controls: @escaping () -> Void) {
        self.pipeline = pipeline
        self.transport = transport; self.disconnect = disconnect
        super.init(frame: .zero)
        backgroundColor = .black; isOpaque = true; layer.isOpaque = true
    }
    required init?(coder: NSCoder) { fatalError("No coder") }
    func updateStatistics(rows: [String], visible: Bool, position: Int) {
        statisticsRows = rows; statisticsVisible = visible
    }
    func refreshPresentationDiagnostics() {}
    func stop() { stopped = true }
    // Exact production admission and edge handlers are injected here.
    __LOCAL_EXIT_HANDLERS__
}
@MainActor private final class SyntheticEdge: UIScreenEdgePanGestureRecognizer {
    var syntheticState: UIGestureRecognizer.State = .possible
    var distance: CGFloat = 0
    override var state: UIGestureRecognizer.State { get { syntheticState } set { syntheticState = newValue } }
    override func translation(in view: UIView?) -> CGPoint { CGPoint(x: distance, y: 0) }
}
@MainActor private extension MobileStreamView {
    func testEdge(state: UIGestureRecognizer.State, distance: CGFloat) {
        let gesture = SyntheticEdge(); gesture.syntheticState = state; gesture.distance = distance
        disconnectFromEdge(gesture)
    }
    func testExitAction() -> Bool { disconnectAction() }
}
'''


HARNESS = r'''
@MainActor private extension MobileStreamPresentationController {
    var testStream: MobileStreamViewController? { streamController }
    __MUTE_OBSERVATION__
    __PENDING_OBSERVATION__
    func testResumeObservation() {
        guard let session else { return }
        self.session = nil
        update(session: session)
    }
}
@MainActor private extension MobileStreamViewController {
    var testSurface: MobileStreamView? { surface }
    var testFeedback: Bool { feedback != nil }
    var testControls: Bool { controls != nil }
    var testControlsTransitioning: Bool { controlsTransitioning }
    var testStopped: Bool { stopped }
}

@MainActor private final class PresentationHarnessApp: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Presentation Harness", sessionRole: session.role)
        configuration.delegateClass = PresentationHarnessScene.self
        return configuration
    }
}
@MainActor private final class PresentationHarnessScene: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo sceneSession: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let session = MobileStreamingSession()
        let presenter = MobileStreamPresentationController()
        presenter.update(session: session)
        presenter.testMuteObservation()
        let library = GCEventViewController()
        library.controllerUserInteractionEnabled = false
        library.view.backgroundColor = .black
        library.addChild(presenter); library.view.addSubview(presenter.view)
        presenter.view.frame = library.view.bounds
        presenter.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        presenter.view.isUserInteractionEnabled = false
        presenter.didMove(toParent: library)
        let libraryContent = UIView(frame: library.view.bounds)
        libraryContent.backgroundColor = .systemBackground; libraryContent.isOpaque = true
        libraryContent.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        library.view.addSubview(libraryContent)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = library; window.makeKeyAndVisible(); self.window = window
        Task { @MainActor in await run(session: session, presenter: presenter) }
    }
    private func check(_ value: Bool, _ description: String) {
        guard value else { print("FAIL: \(description)"); exit(1) }
    }
    private func wait(_ description: String, until condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(30))
        }
        check(false, description)
    }
    private func run(session: MobileStreamingSession, presenter: MobileStreamPresentationController) async {
        await wait("presenter must enter a window") { presenter.view.window != nil }
        check(presenter.presentedViewController == nil, "inactive session must present nothing")

        session.presentationGeneration = 1; session.isActive = true
        presenter.update(session: session)
        await wait("connection feedback must appear before pipeline") {
            presenter.testStream?.testFeedback == true && presenter.presentedViewController != nil
        }
        let first = presenter.testStream!
        let waitingRoot = first.view!
        check(first.testSurface == nil, "waiting must not invent a video surface")
        session.pipeline = HarnessPipeline(1); session.transport = HarnessTransport()
        presenter.update(session: session)
        check(first.view === first.testSurface, "Metal view must become controller root")
        check(first.view.layer is CAMetalLayer && first.view.layer.isOpaque, "root layer must be opaque Metal")
        check(first.testFeedback, "feedback must remain through first-frame wait")
        check(first.view.superview != nil, "root replacement must remain in UIKit presentation container")
        check(waitingRoot.superview == nil, "waiting root must be removed completely after replacement")
        check(first.view.bounds.size == first.view.window?.bounds.size, "Metal root must cover its owning window")

        session.hasVideo = true; session.inputEnabled = true
        presenter.update(session: session)
        check(!first.testFeedback && first.children.isEmpty, "streaming must completely remove feedback host")
        check(first.testSurface?.inputEnabled == true, "stream input must follow session admission")
        session.controlsVisible = true; session.inputEnabled = false
        presenter.update(session: session)
        await wait("controls must present") { first.presentedViewController != nil }
        session.controlsVisible = false; session.inputEnabled = true
        presenter.update(session: session)
        await wait("controls must dismiss and restore surface admission") {
            !first.testControls && first.presentedViewController == nil && first.testSurface?.inputEnabled == true
        }

        // Deliberately omit an inactive publication: SwiftUI may coalesce it.
        let oldSurface = first.testSurface!
        session.presentationGeneration = 2; session.pipeline = HarnessPipeline(2)
        presenter.update(session: session)
        await wait("coalesced reconnect must replace old controller") {
            presenter.testStream?.generation == 2 && presenter.testStream?.testSurface?.pipeline.id == 2
        }
        check(first.testStopped && oldSurface.stopped, "old attempt must stop before replacement")
        check(presenter.testStream !== first, "reconnect must not reuse retired owners")

        // Retire the attempt while UIKit is presenting controls, deliberately
        // delaying the SwiftUI presenter update until its completion arrives.
        let second = presenter.testStream!
        session.controlsVisible = true; session.inputEnabled = false
        presenter.update(session: session)
        check(second.testControlsTransitioning, "controls presentation must be pending for retirement test")
        session.presentationGeneration = 3; session.pipeline = HarnessPipeline(3)
        session.controlsVisible = false; session.inputEnabled = true
        await wait("old controls presentation must finish") { !second.testControlsTransitioning }
        check(second.testControls && second.presentedViewController != nil,
              "stale presentation completion must not use the replacement session's controls state")
        check(!second.testStopped, "stale completion must defer retirement to the native presenter")
        check(!session.controlsVisible, "stale completion must not mutate the replacement session")
        presenter.update(session: session)
        await wait("presenter must retire controls with their captured generation") {
            presenter.testStream?.generation == 3 && presenter.testStream?.testSurface?.pipeline.id == 3
        }
        check(second.testStopped, "retired controls owner must stop before replacement")
        check(presenter.testStream?.testControls == false, "replacement must not inherit old controls")

        // Dismissal completion also arrives after the session changes. It must
        // stop its captured surface and leave the new controls request intact.
        let third = presenter.testStream!
        session.controlsVisible = true; session.inputEnabled = false
        presenter.update(session: session)
        await wait("controls must settle before dismissal retirement test") {
            third.testControls && !third.testControlsTransitioning
        }
        session.controlsVisible = false; session.inputEnabled = true
        presenter.update(session: session)
        check(third.testControlsTransitioning, "controls dismissal must be pending for retirement test")
        session.presentationGeneration = 4; session.pipeline = HarnessPipeline(4)
        session.controlsVisible = true; session.inputEnabled = false
        await wait("stale dismissal completion must retire captured surface") { third.testStopped }
        check(!third.testControls && third.presentedViewController == nil, "retired dismissal must not present new controls")
        check(session.controlsVisible, "retired dismissal must preserve replacement controls request")
        presenter.update(session: session)
        await wait("replacement alone must own the requested controls") {
            presenter.testStream?.generation == 4 && presenter.testStream?.testControls == true &&
                presenter.testStream?.testControlsTransitioning == false
        }
        session.controlsVisible = false; session.inputEnabled = true
        presenter.update(session: session)
        await wait("replacement controls must dismiss") { presenter.testStream?.testControls == false }

        session.isActive = false; session.presentationGeneration = 5
        session.pipeline = nil; session.transport = nil; session.hasVideo = false
        presenter.update(session: session)
        await wait("disconnect must dismiss") { presenter.testStream == nil && presenter.presentedViewController == nil }
        session.isActive = true; session.presentationGeneration = 6
        presenter.update(session: session)
        await wait("second attempt must show feedback") { presenter.testStream?.testFeedback == true }
        session.isActive = false; session.presentationGeneration = 7
        presenter.update(session: session)
        await wait("failure before pipeline must dismiss") { presenter.testStream == nil && presenter.presentedViewController == nil }

        presenter.testResumeObservation()
        session.isActive = true; session.presentationGeneration = 8
        session.transport = HarnessTransport(); session.pipeline = HarnessPipeline(8)
        presenter.update(session: session)
        await wait("owner replacement setup must appear") { presenter.testStream?.testSurface != nil }
        let previousOwner = presenter.testStream!
        let replacement = MobileStreamingSession()
        replacement.presentationGeneration = 8; replacement.isActive = true
        replacement.transport = HarnessTransport(); replacement.pipeline = HarnessPipeline(80)
        presenter.update(session: replacement)
        await wait("different session owner with same generation must replace controller") {
            presenter.testStream?.testSurface?.pipeline.id == 80
        }
        check(previousOwner.testStopped, "owner replacement stops previous native owner")
        session.isActive = false; session.pipeline = nil
        check(!presenter.testPendingObservation, "old-owner publication must not schedule a native update")
        try? await Task.sleep(for: .milliseconds(80))
        check(presenter.testStream?.testSurface?.pipeline.id == 80,
              "cancelled old-owner publication must not alter replacement")
        presenter.testMuteObservation()

        let last = presenter.testStream!
        presenter.stop()
        await wait("dismantle must dismiss") { presenter.presentedViewController == nil }
        check(last.testStopped, "dismantle must stop captured attempt")
        presenter.update(session: replacement)
        check(presenter.testStream == nil, "late update must not revive dismantled presenter")
        let evidence: [String: Any] = ["status": "PASS", "mode": "UIKit-simulator-presentation-lifecycle",
            "checks": ["inactive admission", "feedback before pipeline", "opaque Metal controller root",
                       "feedback removal", "controls dismissal", "coalesced generation retirement",
                       "controls presentation retirement", "controls dismissal retirement",
                       "disconnect", "failure before pipeline", "session owner replacement",
                       "old-owner observation cancellation", "dismantle stale update rejection"],
            "liveVideoTested": false, "hdrCorrectnessTested": false, "directPresentationVerified": false]
        print("PRESENTATION_RESULT " + String(decoding: try! JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]), as: UTF8.self))
        exit(0)
    }
}
@main private struct PresentationHarness {
    @MainActor static func main() {
        UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(PresentationHarnessApp.self))
    }
}
'''


OBSERVATION_HARNESS = r'''
@MainActor private extension MobileStreamPresentationController {
    var testStream: MobileStreamViewController? { streamController }
}
@MainActor private extension MobileStreamViewController {
    var testSurface: MobileStreamView? { surface }
    var testFeedback: Bool { feedback != nil }
    var testControls: Bool { controls != nil }
    var testControlsTransitioning: Bool { controlsTransitioning }
    var testStopped: Bool { stopped }
}
private struct HarnessLibrary: View {
    @ObservedObject var session: MobileStreamingSession
    var body: some View {
        MobileControllerEventContent {
            Text("Computer Library").frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemBackground))
        }
            .background(MobileStreamPresentation(session: session)
                .allowsHitTesting(false).accessibilityHidden(true))
    }
}
// Model a suspended SwiftUI adapter after one initial binding. This second
// probe establishes native observation independence even if the simulator's
// hidden SwiftUI host happens to continue delivering representable updates.
private struct HarnessSuspendedAdapter: UIViewControllerRepresentable {
    let session: MobileStreamingSession
    func makeUIViewController(context: Context) -> UIViewController {
        let presenter = MobileStreamPresentationController()
        presenter.update(session: session)
        return presenter
    }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: UIViewController, coordinator: ()) {
        (controller as? MobileStreamPresentationController)?.stop()
    }
}
private struct HarnessSuspendedLibrary: View {
    let session: MobileStreamingSession
    var body: some View {
        Text("Suspended Computer Library").frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground))
            .background(HarnessSuspendedAdapter(session: session).allowsHitTesting(false))
    }
}
@MainActor private final class PresentationHarnessApp: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Presentation Harness", sessionRole: session.role)
        configuration.delegateClass = PresentationHarnessScene.self
        return configuration
    }
}
@MainActor private final class PresentationHarnessScene: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?
    private var checks: [String] = []
    private var timings: [String: Double] = [:]
    private var presentingHostRemoved = false
    func scene(_ scene: UIScene, willConnectTo sceneSession: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let session = MobileStreamingSession()
        let library = UIHostingController(rootView: HarnessLibrary(session: session))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = library; window.makeKeyAndVisible(); self.window = window
        Task { @MainActor in await run(session: session, library: library) }
    }
    private func result(status: String, failure: String? = nil) {
        var evidence: [String: Any] = ["status": status, "mode": "SwiftUI-native-session-observation",
            "checks": checks, "updateMilliseconds": timings,
            "presentingSwiftUIHostRemovedFromWindow": presentingHostRemoved,
            "manualNormalUpdates": false, "liveVideoTested": false,
            "hdrCorrectnessTested": false, "directPresentationVerified": false]
        if let failure { evidence["failure"] = failure }
        print("PRESENTATION_RESULT " + String(decoding: try! JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]), as: UTF8.self))
        exit(status == "PASS" ? 0 : 1)
    }
    private func check(_ value: Bool, _ description: String) {
        guard value else { result(status: "FAIL", failure: description); return }
        checks.append(description)
    }
    private func wait(_ description: String, milliseconds: Int = 1500,
                      until condition: @MainActor () -> Bool) async {
        let start = ContinuousClock.now
        let deadline = start.advanced(by: .milliseconds(milliseconds))
        while ContinuousClock.now < deadline {
            if condition() {
                let duration = start.duration(to: .now).components
                timings[description] = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
                checks.append(description)
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        result(status: "FAIL", failure: description)
    }
    private func findPresenter(_ controller: UIViewController) -> MobileStreamPresentationController? {
        if let presenter = controller as? MobileStreamPresentationController { return presenter }
        for child in controller.children {
            if let presenter = findPresenter(child) { return presenter }
        }
        return nil
    }
    private func checkEdgeAdmission(window: UIWindow) {
        var exits = 0
        let transport = HarnessTransport()
        let probe = MobileStreamView(pipeline: HarnessPipeline(99), transport: transport, settings: HarnessSettings(),
            toggleStatistics: {}, disconnect: { exits += 1 }, controls: {})
        probe.frame = CGRect(x: 0, y: 0, width: 1000, height: 100)
        window.addSubview(probe)
        probe.inputEnabled = false
        probe.testEdge(state: .began, distance: 0)
        check(transport.releaseCount == 1, "edge begin releases held input")
        probe.testEdge(state: .ended, distance: 449)
        probe.testEdge(state: .cancelled, distance: 1000)
        check(exits == 0, "short and cancelled edge gestures reject local exit")
        probe.testEdge(state: .ended, distance: 450)
        check(exits == 1, "local edge exit remains available with remote input disabled")
        probe.stop(); probe.testEdge(state: .ended, distance: 1000)
        check(exits == 1, "stopped surface rejects local exit")
        probe.removeFromSuperview()
        let detached = MobileStreamView(pipeline: HarnessPipeline(100), transport: transport, settings: HarnessSettings(),
            toggleStatistics: {}, disconnect: { exits += 1 }, controls: {})
        check(!detached.testExitAction(), "surface outside key window rejects local exit")
        let other = UIWindow(windowScene: window.windowScene!)
        other.addSubview(detached)
        check(detached.window === other && !other.isKeyWindow, "non-key window probe is attached")
        check(!detached.testExitAction(), "surface in non-key window rejects local exit")
        detached.removeFromSuperview()
    }
    private func run(session: MobileStreamingSession,
                     library: UIHostingController<HarnessLibrary>) async {
        await wait("actual SwiftUI background representable enters window", milliseconds: 5000) {
            self.findPresenter(library)?.view.window != nil && self.window?.windowScene?.activationState == .foregroundActive
        }
        let presenter = findPresenter(library)!
        check(presenter.presentedViewController == nil, "inactive SwiftUI session presents nothing")
        checkEdgeAdmission(window: window!)
        session.presentationGeneration = 1; session.isActive = true
        await wait("published active state presents connection feedback") {
            presenter.testStream?.testFeedback == true && presenter.presentedViewController != nil
        }
        let first = presenter.testStream!
        await wait("full-screen presentation hides original SwiftUI host") { library.view.window == nil }
        presentingHostRemoved = true
        let waitingRoot = first.view!
        session.transport = HarnessTransport(); session.pipeline = HarnessPipeline(1)
        session.status = "Waiting for video"
        await wait("published pipeline attaches Metal root while SwiftUI host is hidden") {
            first.testSurface?.pipeline.id == 1 && first.view.window != nil
        }
        check(first.view === first.testSurface && first.view.layer is CAMetalLayer && first.view.layer.isOpaque,
              "native streaming root is opaque Metal")
        check(waitingRoot.superview == nil, "waiting root is completely removed")
        session.hasVideo = true; session.inputEnabled = true
        session.statisticsRows = ["FPS 120"]; session.showingStatistics = true
        await wait("published first frame removes feedback and admits input") {
            !first.testFeedback && first.testSurface?.inputEnabled == true
        }
        await wait("published statistics update native surface") {
            first.testSurface?.statisticsVisible == true && first.testSurface?.statisticsRows == ["FPS 120"]
        }
        session.controlsVisible = true; session.inputEnabled = false
        await wait("published controls request presents sheet") {
            first.testControls && !first.testControlsTransitioning && first.presentedViewController != nil
        }
        session.controlsVisible = false
        await wait("published controls close dismisses sheet") {
            !first.testControls && first.presentedViewController == nil
        }
        let retired = first.testSurface!
        session.presentationGeneration = 2; session.pipeline = HarnessPipeline(2)
        await wait("published coalesced reconnect retires captured attempt") {
            presenter.testStream?.generation == 2 && presenter.testStream?.testSurface?.pipeline.id == 2
        }
        check(first.testStopped && retired.stopped, "old native owners stop before reconnect")
        let next = presenter.testStream!.testSurface!
        check(next.inputEnabled == false, "reconnected surface preserves disabled remote admission")
        next.testEdge(state: .ended, distance: next.bounds.width * 0.45)
        await wait("edge callback dismisses native stream before delayed teardown", milliseconds: 1000) {
            session.disconnectBegan && presenter.testStream == nil && presenter.presentedViewController == nil
        }
        check(!session.teardownCompleted, "native dismissal is independent of slow transport teardown")
        await wait("fake transport teardown completes", milliseconds: 3000) { session.teardownCompleted }
        check(library.view.window != nil, "local exit restores original SwiftUI library")

        // This controlled boundary is an observer-sensitivity check; the real
        // representable flow above has no disabled updates or manual drives.
        presenter.stop()
        let isolated = MobileStreamingSession()
        isolated.presentationGeneration = 10; isolated.isActive = true
        let suspended = UIHostingController(rootView: HarnessSuspendedLibrary(session: isolated))
        window!.rootViewController = suspended
        await wait("one-shot SwiftUI adapter presents native waiting controller") {
            self.findPresenter(suspended)?.testStream?.testFeedback == true
        }
        let independent = findPresenter(suspended)!
        await wait("one-shot adapter host leaves window") { suspended.view.window == nil }
        isolated.transport = HarnessTransport(); isolated.pipeline = HarnessPipeline(10)
        await wait("native observation attaches pipeline without any adapter update") {
            independent.testStream?.testSurface?.pipeline.id == 10
        }
        isolated.hasVideo = true
        await wait("native observation removes feedback without adapter update") {
            independent.testStream?.testFeedback == false
        }
        isolated.presentationGeneration = 11; isolated.isActive = false
        await wait("native observation dismisses inactive attempt without adapter update") {
            independent.testStream == nil && independent.presentedViewController == nil
        }
        independent.stop(); result(status: "PASS")
    }
}
@main private struct PresentationHarness {
    @MainActor static func main() {
        UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(PresentationHarnessApp.self))
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("simulator", help="Booted iPhone or iPad simulator UDID")
    parser.add_argument("--mode", choices=("lifecycle", "observation"), default="lifecycle")
    parser.add_argument("--source", type=Path, help="Alternate preserved production source for a baseline run")
    parser.add_argument("--remote-exit-gate", action="store_true",
                        help="Sensitivity probe restoring the former remote-input disconnect gate in generated harness only")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    source = (args.source or root / "Sources/mobile/MobileStreamSurface.swift").read_text()
    controller_adapter = (root / "Sources/mobile/MobileControllerEventContent.swift").read_text()
    presenter = source.split("struct MobileStreamPresentation: UIViewControllerRepresentable", 1)[1]
    presenter = "private struct MobileStreamPresentation: UIViewControllerRepresentable" + presenter.split(
        "/// A dispatch source coalesces callback wakeups.", 1)[0]
    admission = "    private var acceptsLocalStreamActions: Bool {" + source.split(
        "    private var acceptsLocalStreamActions: Bool {", 1)[1].split("    override var canBecomeFirstResponder:", 1)[0]
    edge = "    @objc private func disconnectAction() -> Bool {" + source.split(
        "    @objc private func disconnectAction() -> Bool {", 1)[1].split("    @objc private func clickPointer(", 1)[0]
    if args.remote_exit_gate:
        edge = edge.replace("guard acceptsLocalStreamActions else", "guard acceptsStreamCommands else")
    stubs = STUBS.replace("__LOCAL_EXIT_HANDLERS__", admission + edge)
    mute = "func testMuteObservation() {}"
    pending = "var testPendingObservation: Bool { false }"
    if "private var sessionObservation:" in presenter:
        mute = "func testMuteObservation() { sessionObservation?.cancel(); sessionUpdateTask?.cancel(); sessionUpdateTask = nil }"
        pending = "var testPendingObservation: Bool { sessionUpdateTask != nil }"
    harness = (HARNESS if args.mode == "lifecycle" else OBSERVATION_HARNESS).replace(
        "__MUTE_OBSERVATION__", mute).replace("__PENDING_OBSERVATION__", pending)
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
    architecture = subprocess.check_output(["uname", "-m"], text=True).strip()
    bundle_id = "org.swiftlight.presentation-lifecycle-harness"
    with tempfile.TemporaryDirectory(prefix="swiftlight-mobile-presentation-") as temporary:
        directory = Path(temporary)
        app = directory / "PresentationHarness.app"
        app.mkdir()
        combined = directory / "PresentationHarness.swift"
        combined.write_text(stubs + controller_adapter + presenter + harness)
        module_cache = root / ".build/mobile-presentation-module-cache"
        module_cache.mkdir(parents=True, exist_ok=True)
        subprocess.run(["xcrun", "--sdk", "iphonesimulator", "swiftc", "-swift-version", "6", "-parse-as-library",
                        "-target", f"{architecture}-apple-ios26.0-simulator", "-sdk", sdk,
                        "-module-cache-path", str(module_cache), str(combined),
                        "-o", str(app / "PresentationHarness")], check=True, timeout=120)
        info = {"CFBundleIdentifier": bundle_id, "CFBundleExecutable": "PresentationHarness",
                "CFBundleName": "Presentation Harness", "CFBundleVersion": "1", "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": "1.0", "LSRequiresIPhoneOS": True, "UIDeviceFamily": [1, 2],
                "GCSupportsControllerUserInteraction": True, "UILaunchScreen": {},
                "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False,
                                               "UISceneConfigurations": {"UIWindowSceneSessionRoleApplication": [
                                                   {"UISceneConfigurationName": "Presentation Harness"}]}},
                "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
                                                     "UIInterfaceOrientationLandscapeLeft",
                                                     "UIInterfaceOrientationLandscapeRight"]}
        (app / "Info.plist").write_bytes(plistlib.dumps(info))
        subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, timeout=30)
        subprocess.run(["xcrun", "simctl", "install", args.simulator, str(app)], check=True, timeout=30)
        try:
            run = subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process", "--console",
                                  args.simulator, bundle_id], capture_output=True, text=True, timeout=60)
            print(run.stdout, end="")
            if run.stderr:
                print(run.stderr, end="")
            marker = next((line.split("PRESENTATION_RESULT ", 1)[1] for line in run.stdout.splitlines()
                           if "PRESENTATION_RESULT " in line), None)
            if marker is None:
                return run.returncode or 1
            evidence = json.loads(marker)
            evidence["sourceSHA256"] = hashlib.sha256(source.encode()).hexdigest()
            evidence["controllerAdapterSHA256"] = hashlib.sha256(controller_adapter.encode()).hexdigest()
            evidence["harnessSHA256"] = hashlib.sha256(combined.read_bytes()).hexdigest()
            evidence["simulator"] = args.simulator
            evidence["remoteExitGateSensitivityProbe"] = args.remote_exit_gate
            print(json.dumps(evidence, indent=2, sort_keys=True))
            return 0 if evidence["status"] == "PASS" else 1
        except subprocess.TimeoutExpired as error:
            for output in (error.stdout, error.stderr):
                if output:
                    print(output.decode(errors="replace") if isinstance(output, bytes) else output, end="")
            print("FAIL: simulator launch did not complete within 60 seconds")
            return 1
        finally:
            subprocess.run(["xcrun", "simctl", "uninstall", args.simulator, bundle_id], check=False, timeout=30)


if __name__ == "__main__":
    raise SystemExit(main())

import Foundation
import Testing
@testable import SwiftlightApp
@testable import SwiftlightHost

@Suite(.serialized) @MainActor struct RemoteSessionTests {
    @Test func idlePollingUpdatesAndClearsTheRunningBannerWithoutReloadingApps() async throws {
        let fixture = try await LibraryFixture.make()
        let model = try await fixture.model()
        await fixture.server.setRunning(17)
        try await eventually { model.hostInfo?.currentAppID == 17 }
        #expect(!model.busy && model.message == nil)
        await fixture.server.setRunning(18)
        try await eventually { model.hostInfo?.currentAppID == 18 }
        await fixture.server.setRunning(0)
        try await eventually { model.hostInfo?.currentAppID == 0 }
        #expect(await fixture.server.operations.filter { $0 == "applist" }.count == 1)
        await model.shutdown()
        let count = await fixture.server.operations.count
        try await Task.sleep(for: .milliseconds(80))
        #expect(await fixture.server.operations.count == count)
    }

    @Test func backgroundFailurePreservesLibraryAndRecoversWithoutAlerts() async throws {
        let fixture = try await LibraryFixture.make(running: 17)
        let model = try await fixture.model()
        await fixture.server.setFailure(.timeout)
        try await eventually { model.hostStatus.contains("Offline") }
        #expect(model.hostInfo == nil && model.apps.count == 2 && model.message == nil)
        await fixture.server.setFailure(nil)
        await fixture.server.setRunning(18)
        try await eventually { model.hostInfo?.currentAppID == 18 }
        #expect(model.message == nil)
        await model.shutdown()
    }

    @Test func slowPollDoesNotOverlapOrOverwriteANewHost() async throws {
        let first = try await LibraryFixture.make(running: 17)
        let second = try await LibraryFixture.make(id: "second", running: 18)
        let model = try await first.model()
        await first.server.holdNextStatus()
        try await eventually { await first.server.isHolding }
        let before = await first.server.operations.count
        try await Task.sleep(for: .milliseconds(80))
        #expect(await first.server.operations.count == before)
        model.hosts.append(second.host)
        model.selectHost(second.host, using: second.client)
        try await eventually { !model.busy && model.hostInfo?.id == "second" }
        await first.server.releaseStatus()
        try await Task.sleep(for: .milliseconds(80))
        #expect(model.hostInfo?.id == "second" && model.hostInfo?.currentAppID == 18)
        await model.shutdown()
    }

    @Test func selectingAnotherAppPromptsBeforeOpeningAStreamWindow() async throws {
        let fixture = try await LibraryFixture.make(running: 17)
        let model = try await fixture.model()
        model.launch(RemoteApp(id: 18, name: "Game"))
        try await eventually { !model.busy && model.remoteApplicationAction != nil }
        #expect(model.remoteApplicationAction?.runningApp.name == "Desktop")
        #expect(model.remoteApplicationAction?.nextApp?.id == 18)
        #expect(!model.isSessionActive && model.activeApp == nil && model.message == nil)
        model.remoteApplicationAction = nil // Dismiss/Cancel must have no host side effects.
        #expect(await fixture.server.mutations.isEmpty)
        await model.shutdown()
    }

    @Test func launchCancelsAnOlderPollBeforePresentingFreshSessionState() async throws {
        let fixture = try await LibraryFixture.make()
        let model = try await fixture.model()
        await fixture.server.holdNextStatus()
        try await eventually { await fixture.server.isHolding }
        await fixture.server.setRunning(17)
        model.launch(RemoteApp(id: 18, name: "Game"))
        try await eventually { !model.busy && model.remoteApplicationAction != nil }
        await fixture.server.releaseStatus()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.hostInfo?.currentAppID == 17)
        #expect(model.remoteApplicationAction?.runningApp.id == 17)
        #expect(await fixture.server.mutations.isEmpty)
        await model.shutdown()
    }

    @Test func confirmedSwitchEntersTheSelectedAppsStreamLifecycle() async throws {
        let fixture = try await LibraryFixture.make(running: 17)
        let model = try await fixture.model()
        model.launch(RemoteApp(id: 18, name: "Game"))
        try await eventually { !model.busy && model.remoteApplicationAction != nil }
        model.confirmRemoteApplicationAction(try #require(model.remoteApplicationAction))
        try await eventually { model.activeApp?.id == 18 }
        #expect(await fixture.server.mutations == ["cancel"])
        // The headless model reaches window preparation, which has no window in
        // this fixture. Media transport is deliberately not started by this test.
        await model.shutdown()
    }

    @Test func changedRunningAppNeedsANewConfirmation() async throws {
        let fixture = try await LibraryFixture.make(running: 17)
        let model = try await fixture.model()
        model.launch(RemoteApp(id: 18, name: "Game"))
        try await eventually { !model.busy && model.remoteApplicationAction != nil }
        let action = try #require(model.remoteApplicationAction)
        await fixture.server.setRunning(19)
        model.confirmRemoteApplicationAction(action)
        try await eventually { !model.busy && model.remoteApplicationAction?.runningApp.id == 19 }
        #expect(model.remoteApplicationAction?.nextApp?.id == 18)
        #expect(await fixture.server.mutations.isEmpty)
        #expect(model.libraryApps.contains { $0.id == 19 })
        await model.shutdown()
    }

    @Test func failedQuitDoesNotLaunchOrEraseTheLibrary() async throws {
        let fixture = try await LibraryFixture.make(running: 17)
        let model = try await fixture.model()
        await fixture.server.setRefuseQuit(true)
        model.launch(RemoteApp(id: 18, name: "Game"))
        try await eventually { !model.busy && model.remoteApplicationAction != nil }
        model.confirmRemoteApplicationAction(try #require(model.remoteApplicationAction))
        try await eventually { !model.busy && model.message != nil }
        #expect(await fixture.server.mutations == ["cancel"])
        #expect(model.apps.count == 2 && model.activeApp == nil && !model.isSessionActive)
        await model.shutdown()
    }

    @Test func trustFailureDuringPrepareClearsAuthenticatedLibraryWithoutLaunching() async throws {
        for failure in [HostError.certificateChanged, .identityChanged] {
            let fixture = try await LibraryFixture.make(running: 17)
            // Slow polling prevents a later poll from hiding a broken action catch.
            let model = try await fixture.model(pollingInterval: .seconds(60))
            await fixture.server.setTrustFailure(failure)
            model.launch(RemoteApp(id: 18, name: "Game"))
            try await eventually { !model.busy && model.message != nil }
            #expect(model.hostInfo == nil && model.apps.isEmpty && model.libraryApps.isEmpty)
            #expect(model.hostStatus == "Trust needs review")
            #expect(model.remoteApplicationAction == nil && model.activeApp == nil && !model.isSessionActive)
            #expect(await fixture.server.mutations.isEmpty)
            await model.shutdown()
            #expect(await fixture.vault.pinMutationCount == 0)
        }
    }

    @Test func trustFailureBeforeConfirmedQuitClearsLibraryWithoutSendingCancel() async throws {
        for failure in [HostError.certificateChanged, .identityChanged] {
            for replacingApp in [false, true] {
                let fixture = try await LibraryFixture.make(running: 17)
                let model = try await fixture.model(pollingInterval: .seconds(60))
                let action = try await remoteAction(model, replacingApp: replacingApp)
                await fixture.server.setTrustFailure(failure)
                model.confirmRemoteApplicationAction(action)
                try await eventually { !model.busy && model.message != nil }
                #expect(model.hostInfo == nil && model.apps.isEmpty && model.libraryApps.isEmpty)
                #expect(model.hostStatus == "Trust needs review")
                #expect(model.remoteApplicationAction == nil && model.activeApp == nil && !model.isSessionActive)
                #expect(await fixture.server.mutations.isEmpty)
                await model.shutdown()
                #expect(await fixture.vault.pinMutationCount == 0)
            }
        }
    }

    @Test func trustFailureVerifyingQuitClearsLibraryAndNeverFallsThroughToLaunch() async throws {
        for failure in [HostError.certificateChanged, .identityChanged] {
            for replacingApp in [false, true] {
                let fixture = try await LibraryFixture.make(running: 17)
                let model = try await fixture.model(pollingInterval: .seconds(60))
                let action = try await remoteAction(model, replacingApp: replacingApp)
                await fixture.server.setTrustFailure(failure, afterCancel: true)
                model.confirmRemoteApplicationAction(action)
                try await eventually { !model.busy && model.message != nil }
                #expect(model.hostInfo == nil && model.apps.isEmpty && model.libraryApps.isEmpty)
                #expect(model.hostStatus == "Trust needs review")
                #expect(model.remoteApplicationAction == nil && model.activeApp == nil && !model.isSessionActive)
                // Only the explicitly confirmed cancel used the original trusted
                // host. Failed verification cannot launch or resume anything else.
                #expect(await fixture.server.mutations == ["cancel"])
                await model.shutdown()
                #expect(await fixture.vault.pinMutationCount == 0)
            }
        }
    }

    @Test func contextQuitOnlyTargetsTheRunningAppAndRefreshesStatus() async throws {
        let fixture = try await LibraryFixture.make(running: 17)
        let model = try await fixture.model()
        model.requestQuitRemoteApplication(RemoteApp(id: 18, name: "Game"))
        #expect(model.remoteApplicationAction == nil)
        model.requestQuitRemoteApplication(RemoteApp(id: 17, name: "Desktop"))
        let action = try #require(model.remoteApplicationAction)
        #expect(action.nextApp == nil)
        model.confirmRemoteApplicationAction(action)
        try await eventually { !model.busy && model.hostInfo?.currentAppID == 0 }
        #expect(await fixture.server.mutations == ["cancel"])
        await model.shutdown()
    }

    @Test func oldHostConfirmationCannotQuitTheNewHost() async throws {
        let first = try await LibraryFixture.make(running: 17)
        let second = try await LibraryFixture.make(id: "second", running: 17)
        let model = try await first.model()
        model.requestQuitRemoteApplication(RemoteApp(id: 17, name: "Desktop"))
        let action = try #require(model.remoteApplicationAction)
        model.hosts.append(second.host)
        model.selectHost(second.host, using: second.client)
        try await eventually { !model.busy }
        model.confirmRemoteApplicationAction(action)
        #expect(await first.server.mutations.isEmpty)
        #expect(await second.server.mutations.isEmpty)
        await model.shutdown()
    }

    @Test func confirmedSwitchVerifiesQuitBeforeLaunchingAndSameAppResumes() async throws {
        let fixture = try await LibraryFixture.make(running: 17)
        let request = try StreamLaunchRequest(appID: 18, width: 1920, height: 1080, fps: 60,
                                            inputKey: Data(repeating: 0, count: 16), inputKeyID: 1)
        #expect(try await fixture.client.prepareApplication(18, quitting: 17).currentAppID == 0)
        _ = try await fixture.client.launchOrResume(request)
        #expect(await fixture.server.mutations == ["cancel", "launch"])
        let operations = await fixture.server.operations
        let cancel = try #require(operations.firstIndex(of: "cancel"))
        let launch = try #require(operations.firstIndex(of: "launch"))
        #expect(operations[(cancel + 1)..<launch].contains("serverinfo"))
        #expect(try await fixture.client.prepareApplication(18).currentAppID == 18)
        _ = try await fixture.client.launchOrResume(request)
        #expect(await fixture.server.mutations == ["cancel", "launch", "resume"])
    }

    @Test func launchRaceAndExpiredConfirmationDoNotQuitAnUnconfirmedApp() async throws {
        let fixture = try await LibraryFixture.make()
        _ = try await fixture.client.prepareApplication(18)
        await fixture.server.setRunning(19)
        let request = try StreamLaunchRequest(appID: 18, width: 1920, height: 1080, fps: 60,
                                            inputKey: Data(repeating: 0, count: 16), inputKeyID: 1)
        await #expect(throws: RunningApplicationConflict.self) { try await fixture.client.launchOrResume(request) }
        await #expect(throws: RunningApplicationConflict.self) { try await fixture.client.quitApplication(expectedAppID: 17) }
        #expect(await fixture.server.mutations.isEmpty)
        await fixture.server.setRunning(0)
        _ = try await fixture.client.prepareApplication(18, quitting: 17)
        try await fixture.client.quitApplication(expectedAppID: 17)
        #expect(await fixture.server.mutations.isEmpty)
    }

    @Test func pollsPauseDuringStreamLifecycleAndResumeAfterDisconnect() async throws {
        let fixture = try await LibraryFixture.make()
        let model = try await fixture.model()
        model.state.apply(.connect)
        try await Task.sleep(for: .milliseconds(80))
        let count = await fixture.server.operations.count
        try await Task.sleep(for: .milliseconds(80))
        #expect(await fixture.server.operations.count == count)
        await fixture.server.setRunning(17)
        model.disconnect()
        try await eventually { model.hostInfo?.currentAppID == 17 }
        model.suspend()
        let sleepingCount = await fixture.server.operations.count
        try await Task.sleep(for: .milliseconds(80))
        #expect(await fixture.server.operations.count == sleepingCount)
        await model.shutdown()
    }
}

@MainActor private func remoteAction(_ model: ClientModel, replacingApp: Bool) async throws -> RemoteApplicationAction {
    if replacingApp { model.launch(RemoteApp(id: 18, name: "Game")) }
    else { model.requestQuitRemoteApplication(RemoteApp(id: 17, name: "Desktop")) }
    try await eventually { !model.busy && model.remoteApplicationAction != nil }
    return try #require(model.remoteApplicationAction)
}

@MainActor private func eventually(_ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await condition()) {
        try #require(ContinuousClock.now < deadline, "Timed out waiting for session state")
        try await Task.sleep(for: .milliseconds(5))
    }
}

private struct LibraryFixture {
    let host: SavedHost
    let client: HostClient
    let server: LibraryServer
    let vault: LibraryVault
    static func make(id: String = "fixture", running: Int = 0) async throws -> Self {
        let vault = try LibraryVault()
        let address = try HostAddress(id + ".invalid")
        let server = LibraryServer(id: id, running: running)
        let client = HostClient(address: address, hostID: id, identityStore: vault, transport: server)
        return Self(host: SavedHost(id: id, name: id, address: address), client: client, server: server, vault: vault)
    }
    @MainActor func model(pollingInterval: Duration = .milliseconds(20)) async throws -> ClientModel {
        let model = ClientModel(startServices: false, pollingInterval: pollingInterval)
        model.hosts = [host]
        model.selectHost(host, using: client)
        try await eventually { !model.busy }
        #expect(model.apps.count == 2)
        return model
    }
}

private actor LibraryVault: HostIdentityProviding {
    let envelope: HostIdentityEnvelope
    var pinMutationCount = 0
    init() throws { envelope = try HostIdentityEnvelope.generate() }
    func identity() -> HostIdentityEnvelope { envelope }
    func pin(_ key: String) -> Data? { Data([1]) }
    func savePin(_ certificate: Data, keys: [String]) { pinMutationCount += 1 }
    func removePins(_ keys: [String]) { pinMutationCount += 1 }
}

/// In-memory wire peer: no network, Keychain, or running host is touched.
private actor LibraryServer: HostHTTPTransport {
    let id: String
    var running: Int
    var operations: [String] = []
    var mutations: [String] { operations.filter { ["cancel", "launch", "resume"].contains($0) } }
    var failure: HostError?
    var failureAfterCancel: HostError?
    var reportedID: String?
    var refuseQuit = false
    var hold = false
    var held: CheckedContinuation<Void, Never>?
    var isHolding: Bool { held != nil }
    init(id: String, running: Int) { self.id = id; self.running = running }
    func setRunning(_ id: Int) { running = id }
    func setFailure(_ error: HostError?) { failure = error }
    func setTrustFailure(_ error: HostError, afterCancel: Bool = false) {
        if afterCancel { failureAfterCancel = error }
        else if error == .identityChanged { reportedID = id + "-changed" }
        else { failure = error }
    }
    func setRefuseQuit(_ value: Bool) { refuseQuit = value }
    func holdNextStatus() { hold = true }
    func releaseStatus() { held?.resume(); held = nil }
    func fetch(_ request: HostHTTPRequest, identity: HostIdentityEnvelope, pin: Data?) async throws -> Data {
        let path = request.url.lastPathComponent
        operations.append(path)
        switch path {
        case "serverinfo":
            if let failure { throw failure }
            let snapshot = running
            if hold {
                hold = false
                // Intentionally ignore cancellation to exercise stale completion rejection.
                await withCheckedContinuation { held = $0 }
            }
            return xml("<hostname>Fixture</hostname><uniqueid>\(reportedID ?? id)</uniqueid><appversion>7.1.0.0</appversion><PairStatus>1</PairStatus><currentgame>\(snapshot)</currentgame><ServerCodecModeSupport>65793</ServerCodecModeSupport>")
        case "applist": return xml("<App><ID>17</ID><AppTitle>Desktop</AppTitle></App><App><ID>18</ID><AppTitle>Game</AppTitle></App>")
        case "cancel":
            if !refuseQuit { running = 0 }
            if let failureAfterCancel { setTrustFailure(failureAfterCancel) }
            return xml("<cancel>1</cancel>")
        case "launch", "resume":
            let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems
            running = Int(query?.first { $0.name == "appid" }?.value ?? "") ?? 0
            return xml("<sessionUrl0>rtsp://fixture.invalid:48010</sessionUrl0>")
        default: throw HostError.invalidArtwork
        }
    }
    private func xml(_ body: String) -> Data { Data("<root status_code=\"200\">\(body)</root>".utf8) }
}

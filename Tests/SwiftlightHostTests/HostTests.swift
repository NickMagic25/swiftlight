import Foundation
import Security
import Testing
@testable import SwiftlightHost

@Test func keychainBackendRoutesWithoutAccessingCredentials() {
    let protected = HostKeychainConfiguration(service: "synthetic.test", backend: .dataProtection)
    let protectedQuery = protected.query(account: "test-account")
    #expect(protectedQuery[kSecUseDataProtectionKeychain as String] as? Bool == true)
    #expect(protectedQuery[kSecAttrSynchronizable as String] as? Bool == false)
    #expect(protectedQuery[kSecAttrService as String] as? String == "synthetic.test")
    #expect(protected.item(account: "test-account", data: Data())[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    #if os(macOS)
    #expect(HostKeychainBackend.applicationDefault == .login)
    let login = HostKeychainConfiguration(service: "synthetic.test", backend: .login)
    #expect(login.query(account: "test-account")[kSecUseDataProtectionKeychain as String] as? Bool == false)
    #expect(login.query(account: "test-account")[kSecAttrSynchronizable as String] as? Bool == false)
    #expect(login.item(account: "test-account", data: Data())[kSecAttrAccessible as String] == nil)
    #else
    #expect(HostKeychainBackend.applicationDefault == .dataProtection)
    #endif
}

@Test func addressesAndApolloLinks() throws {
    #expect(try HostAddress("host.local:48089").httpPort == 48089)
    #expect(try HostAddress("192.0.2.7").description == "192.0.2.7:47989")
    #expect(try HostAddress("2001:db8::7").host == "2001:db8::7")
    let ipv6 = try HostAddress("[2001:db8::7]:48089")
    #expect(ipv6.host == "2001:db8::7")
    #expect(try ipv6.url(path: "serverinfo", secure: false).absoluteString == "http://[2001:db8::7]:48089/serverinfo")
    for bad in ["", "host:0", "host:65536", "http://user:password@host", "host/path", "host?pin=1234", "host#fragment", "invalid:ip:v6"] {
        #expect(throws: (any Error).self) { try HostAddress(bad) }
    }
    let credential = try ApolloPairingCredential(link: "art://[2001:db8::7]:48089?pin=0007&passphrase=caf%C3%A9%20%2B%20%26&name=My%20PC")
    #expect(credential.address == ipv6)
    #expect(credential.hostName == "My PC")
    #expect(credential.passphrase == "café + &")
    #expect(!String(reflecting: credential).contains("café"))
    for bad in ["https://host?pin=1234&passphrase=a", "art://host?pin=1234", "art://host?pin=1234&pin=4567&passphrase=a", "art://host?pin=１２３４&passphrase=a", "art://user@host?pin=1234&passphrase=a", "art://host?pin=1234&passphrase=%ZZ"] {
        #expect(throws: HostError.malformedPairingLink) { try ApolloPairingCredential(link: bad) }
    }
    #expect(try HostAddress("[fe80::1%en0]:48089").host == "fe80::1%en0")
    #expect(normalizedTLSHost("[fe80::1%25en0]") == "fe80::1%en0")
}

@Test func apolloCrossLanguageVectors() throws {
    let address = try HostAddress("example.local")
    let first = try ApolloPairingCredential(address: address, otp: "1234", passphrase: "Moonlight123")
    #expect(first.authentication(salt: Data(0..<16)) == "2F4ADF9E38D2CEAA59290F38B3B552443CA2FADC9B330A08BB0668D109688DEA")
    let second = try ApolloPairingCredential(address: address, otp: "0007", passphrase: "café + &")
    #expect(second.authentication(salt: try Data(strictHex: "FFEEDDCCBBAA99887766554433221100")) == "7252EB2645E5F50C7EB00770D31B1BA183C8DBA0EAE82038E0664A234103C872")
}

@Test func xmlProtocolBoundaries() throws {
    let xml = try HostXML(data: Data("<root status_code=\"200\"><App><ID>17</ID><AppTitle>A &amp; B</AppTitle><IsHdrSupported>1</IsHdrSupported></App><App><ID>18</ID><AppTitle>Desktop</AppTitle></App></root>".utf8))
    #expect(try xml.apps() == [RemoteApp(id: 17, name: "A & B", supportsHDR: true), RemoteApp(id: 18, name: "Desktop")])
    #expect(throws: HostError.permissionDenied) { try HostXML(data: Data("<root status_code=\"403\"/>".utf8)) }
    #expect(throws: HostError.invalidResponse) { try HostXML(data: Data("<root><paired>1</paired></root>".utf8)) }
    #expect(throws: HostError.invalidResponse) { try HostXML(data: Data("<!DOCTYPE root [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><root status_code=\"200\">&x;</root>".utf8)) }
    #expect(throws: HostError.invalidResponse) { try Data(strictHex: "Z0") }
    #expect(throws: HostError.invalidResponse) { try Data(strictHex: "012") }
    let permissionApp = try HostXML(data: Data("<root status_code=\"200\"><App><ID>114514</ID><AppTitle>Permission Denied</AppTitle></App></root>".utf8))
    #expect(throws: HostError.permissionDenied) { try permissionApp.apps() }
}

@Test func cryptoInteroperabilityAndTamperRejection() throws {
    // AES-128 ECB known-answer vector (FIPS 197 Appendix C.1).
    let key = try Data(strictHex: "000102030405060708090A0B0C0D0E0F")
    let plain = try Data(strictHex: "00112233445566778899AABBCCDDEEFF")
    let cipher = try PairingCrypto.aes(plain, key: key, encrypt: true)
    #expect(cipher.hex == "69C4E0D86A7B0430D8CDB78070B4C55A")
    #expect(try PairingCrypto.aes(cipher, key: key, encrypt: false) == plain)
    #expect(throws: HostError.invalidResponse) { try PairingCrypto.aes(Data([1]), key: key, encrypt: true) }
    let identity = try HostIdentityEnvelope.generate()
    let signature = try PairingCrypto.sign(plain, key: identity.privateKey)
    #expect(PairingCrypto.verify(plain, signature: signature, certificate: identity.certificate))
    #expect(!PairingCrypto.verify(Data(repeating: 0, count: 16), signature: signature, certificate: identity.certificate))
    let der = try PairingCrypto.der(identity.certificate)
    #expect(SecCertificateCreateWithData(nil, der as CFData) != nil)
    if #available(macOS 15, iOS 18, tvOS 18, *) {
        // In-memory import deliberately avoids writing test identities to Keychain.
        let imported = try identity.tlsIdentity()
        var cert: SecCertificate?
        #expect(SecIdentityCopyCertificate(imported, &cert) == errSecSuccess)
        #expect(cert.map { SecCertificateCopyData($0) as Data } == der)
    }
}

@Test func fullPINPairingPinsOnlyAfterAuthenticatedChallenge() async throws {
    let vault = try TestIdentityVault(), server = try FixtureServer()
    let address = try HostAddress("fixture.invalid")
    let client = HostClient(address: address, identityStore: vault, transport: server)
    let info = try await client.pair(pin: "1234")
    #expect(info.isPaired)
    let pin = try await vault.pin(address.description)
    #expect(pin == server.certificateDER)
    let operations = await server.operations
    #expect(operations == ["http:serverinfo", "http:serverinfo", "http:getservercert", "http:clientchallenge", "http:serverchallengeresp", "http:clientpairingsecret", "https:pairchallenge", "https:serverinfo"])
    #expect(try await client.apps().first?.name == "Desktop")
    var launch = try StreamLaunchRequest(appID: 17, width: 2560, height: 1600, fps: 120, inputKey: Data(repeating: 42, count: 16), inputKeyID: 0x80000001)
    for surround: UInt32 in [0x00030002, 0x003F0006, 0x063F0008] {
        launch.surroundAudioInfo = surround
        launch.playAudioOnHost = surround != 0x00030002
        #expect(try await client.launch(launch).sessionURL == "rtsp://fixture.invalid:48010")
        #expect(await server.launchAudioInfo == String(surround))
        #expect(await server.launchHostAudio == (launch.playAudioOnHost ? "1" : "0"))
        #expect(try await client.resume(launch).sessionURL == "rtsp://fixture.invalid:48010")
        #expect(await server.launchAudioInfo == String(surround))
    }
    #expect(await server.launchMode == "2560x1600x120")
    #expect(await server.launchKeyID == "-2147483647")
    #expect(await server.operations.contains("https:cancel") == false)
    try await client.quitApplication()
    #expect(await server.operations.last == "https:serverinfo")
    #expect(await server.operations.contains("https:cancel"))
    try await client.forgetPairing()
    #expect(try await vault.pin(address.description) == nil)
    #expect(try await vault.pin(info.id) == nil)
}

@Test func wrongPINAndTamperedProofNeverPersistTrust() async throws {
    for tamper in [false, true] {
        let vault = try TestIdentityVault(), server = try FixtureServer(tamperSignature: tamper)
        let address = try HostAddress("fixture.invalid")
        let client = HostClient(address: address, identityStore: vault, transport: server)
        await #expect(throws: tamper ? HostError.cryptoFailure : HostError.incorrectPIN) {
            try await client.pair(pin: tamper ? "1234" : "4321")
        }
        #expect(try await vault.pin(address.description) == nil)
        #expect(await server.operations.last == "http:unpair")
    }
}

@Test func apolloPairingAndCredentialFailure() async throws {
    for valid in [true, false] {
        let vault = try TestIdentityVault(), server = try FixtureServer(passphrase: "Moonlight123")
        let address = try HostAddress("fixture.invalid")
        let client = HostClient(address: address, identityStore: vault, transport: server)
        let credential = try ApolloPairingCredential(address: address, otp: "1234", passphrase: valid ? "Moonlight123" : "wrong")
        if valid { #expect(try await client.pair(credential: credential).isPaired) }
        else {
            await #expect(throws: HostError.credentialRejected) { try await client.pair(credential: credential) }
            #expect(try await vault.pin(address.description) == nil)
        }
    }
}

@Test func cancellationCleansPendingPairing() async throws {
    let vault = try TestIdentityVault(), server = try FixtureServer(waitForPIN: true)
    let address = try HostAddress("fixture.invalid")
    let client = HostClient(address: address, identityStore: vault, transport: server)
    let task = Task { try await client.pair(pin: "1234") }
    await server.waitUntilPairingStarts()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await server.operations.last == "http:unpair")
    #expect(try await vault.pin(address.description) == nil)
}

@Test func changedCertificateCannotFallBackToHTTP() async throws {
    let vault = try TestIdentityVault(), server = try FixtureServer()
    let address = try HostAddress("fixture.invalid")
    try await vault.savePin(Data([1, 2, 3]), keys: [address.description])
    let client = HostClient(address: address, identityStore: vault, transport: server)
    await #expect(throws: HostError.certificateChanged) { try await client.serverInfo() }
    #expect(await server.operations == ["http:serverinfo", "https:serverinfo"])
    #expect(try await vault.pin(address.description) == Data([1, 2, 3]))
}

@Test func untrustedPairStatusCannotHidePairingFlow() async throws {
    let vault = try TestIdentityVault(), server = try FixtureServer(reportsPaired: true)
    let address = try HostAddress("fixture.invalid")
    let client = HostClient(address: address, identityStore: vault, transport: server)
    let info = try await client.serverInfo()
    #expect(info.isPaired == false)
    #expect(info.rawFields["PairStatus"] == "1")
    #expect(try await vault.pin(address.description) == nil)
    await #expect(throws: HostError.notPaired) { try await client.apps() }
    #expect(await server.operations == ["http:serverinfo", "http:serverinfo"])
    // A stale/spoofed HTTP status does not prevent completing the normal PIN flow.
    #expect(try await client.pair(pin: "1234").isPaired)
    #expect(try await client.serverInfo().isPaired)
}

@Test func newAddressFindsExistingHostIDPinBeforeReturningStatus() async throws {
    let vault = try TestIdentityVault(), server = try FixtureServer(reportsPaired: true)
    try await vault.savePin(server.certificateDER, keys: ["fixture-host"])
    let client = HostClient(address: try HostAddress("alias.fixture.invalid"), identityStore: vault, transport: server)
    #expect(try await client.serverInfo().isPaired)
    #expect(await server.operations == ["http:serverinfo", "https:serverinfo"])
}

@Test func existingPinWithUnpairedHostCannotReportPairingSuccess() async throws {
    let vault = try TestIdentityVault(), server = try FixtureServer()
    let address = try HostAddress("fixture.invalid")
    try await vault.savePin(server.certificateDER, keys: [address.description])
    let client = HostClient(address: address, identityStore: vault, transport: server)
    await #expect(throws: HostError.pairingFailed) { try await client.pair(pin: "1234") }
    #expect(await server.operations == ["http:serverinfo", "https:serverinfo"])
    #expect(try await vault.pin(address.description) == server.certificateDER)
}

@Test func savedHostsContainOnlyMetadata() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("hosts.json"), store = SavedHostStore(url: folder.appendingPathComponent("hosts.json"))
    let address = try HostAddress("example.local")
    try await store.upsert(SavedHost(id: "host-id", name: "My PC", address: address))
    #expect(try await store.load().count == 1)
    try await store.upsert(SavedHost(id: "host-id", name: "Renamed PC", address: address))
    #expect(try await store.load().first?.name == "Renamed PC")
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(!text.contains("privateKey")); #expect(!text.contains("certificate")); #expect(!text.contains("passphrase"))
    try await store.remove(id: "host-id")
    #expect(try await store.load().isEmpty)
}

private actor TestIdentityVault: HostIdentityProviding {
    let envelope: HostIdentityEnvelope
    var pins: [String: Data] = [:]
    init() throws { envelope = try HostIdentityEnvelope.generate() }
    func identity() throws -> HostIdentityEnvelope { envelope }
    func pin(_ key: String) throws -> Data? { pins[key] }
    func savePin(_ certificate: Data, keys: [String]) throws { for key in keys { pins[key] = certificate } }
    func removePins(_ keys: [String]) throws { for key in keys { pins.removeValue(forKey: key) } }
}

/// A deterministic in-process protocol peer. This does not contact a host or Keychain.
private actor FixtureServer: HostHTTPTransport {
    let envelope: HostIdentityEnvelope
    let certificateDER: Data
    let passphrase: String?
    let tamperSignature: Bool
    let waitForPIN: Bool
    var operations: [String] = []
    var launchMode: String?, launchKeyID: String?, launchAudioInfo: String?, launchHostAudio: String?
    var key = Data(), clientCertificate = Data(), clientHash = Data()
    let secret = Data(repeating: 0x42, count: 16), challenge = Data(repeating: 0x17, count: 16)
    var paired = false, running = false
    private var pairingWaiters: [CheckedContinuation<Void, Never>] = []
    init(passphrase: String? = nil, tamperSignature: Bool = false, waitForPIN: Bool = false, reportsPaired: Bool = false) throws {
        envelope = try HostIdentityEnvelope.generate(); certificateDER = try PairingCrypto.der(envelope.certificate)
        self.passphrase = passphrase; self.tamperSignature = tamperSignature; self.waitForPIN = waitForPIN; paired = reportsPaired
    }
    func waitUntilPairingStarts() async {
        if operations.contains("http:getservercert") { return }
        await withCheckedContinuation { pairingWaiters.append($0) }
    }
    func fetch(_ request: HostHTTPRequest, identity: HostIdentityEnvelope, pin: Data?) async throws -> Data {
        let parts = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
        let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let path = String(parts.path.dropFirst())
        let phase = query["phrase"] ?? ["clientchallenge", "serverchallengeresp", "clientpairingsecret"].first(where: { query[$0] != nil }) ?? path
        operations.append("\(parts.scheme!):\(phase)")
        #expect(query["uniqueid"] == identity.uniqueID)
        if parts.scheme == "https", pin != certificateDER { throw HostError.certificateChanged }
        switch phase {
        case "serverinfo":
            return xml("<hostname>Fixture</hostname><uniqueid>fixture-host</uniqueid><appversion>7.1.0.0</appversion><HttpsPort>47984</HttpsPort><PairStatus>\(paired ? 1 : 0)</PairStatus><currentgame>\(running ? 17 : 0)</currentgame><ServerCodecModeSupport>65793</ServerCodecModeSupport>" + (passphrase == nil ? "" : "<Permission>119480064</Permission>"))
        case "getservercert":
            pairingWaiters.forEach { $0.resume() }; pairingWaiters.removeAll()
            if waitForPIN { try await Task.sleep(for: .seconds(120)) }
            let salt = try Data(strictHex: query["salt"]!)
            clientCertificate = try Data(strictHex: query["clientcert"]!)
            var effectivePIN = "1234"
            if let passphrase {
                let expected = PairingCrypto.sha256(Data(("1234" + salt.hex + passphrase).utf8)).hex
                if query["otpauth"] != expected { effectivePIN = "unavailable" }
            }
            key = Data(PairingCrypto.sha256(salt + Data(effectivePIN.utf8)).prefix(16))
            return xml("<paired>1</paired><plaincert>\(envelope.certificate.hex)</plaincert>")
        case "clientchallenge":
            let clientChallenge = try PairingCrypto.aes(Data(strictHex: query[phase]!), key: key, encrypt: false)
            let hash = try PairingCrypto.sha256(clientChallenge + PairingCrypto.signature(envelope.certificate) + secret)
            let response = try PairingCrypto.aes(hash + challenge, key: key, encrypt: true)
            return xml("<paired>1</paired><challengeresponse>\(response.hex)</challengeresponse>")
        case "serverchallengeresp":
            clientHash = try PairingCrypto.aes(Data(strictHex: query[phase]!), key: key, encrypt: false)
            var signature = try PairingCrypto.sign(secret, key: envelope.privateKey)
            if tamperSignature { signature[0] ^= 1 }
            return xml("<paired>1</paired><pairingsecret>\((secret + signature).hex)</pairingsecret>")
        case "clientpairingsecret":
            let proof = try Data(strictHex: query[phase]!), secret = Data(proof.prefix(16)), signature = Data(proof.dropFirst(16))
            #expect(PairingCrypto.verify(secret, signature: signature, certificate: clientCertificate))
            #expect(try PairingCrypto.sha256(challenge + PairingCrypto.signature(clientCertificate) + secret) == clientHash)
            paired = true; return xml("<paired>1</paired>")
        case "pairchallenge": return xml("<paired>\(paired ? 1 : 0)</paired>")
        case "unpair": paired = false; return xml("<paired>0</paired>")
        case "applist": return xml("<App><ID>17</ID><AppTitle>Desktop</AppTitle></App>")
        case "launch", "resume":
            running = true; launchMode = query["mode"]; launchKeyID = query["rikeyid"]
            launchAudioInfo = query["surroundAudioInfo"]; launchHostAudio = query["localAudioPlayMode"]
            return xml("<sessionUrl0>rtsp://fixture.invalid:48010</sessionUrl0>")
        case "cancel": running = false; return xml("<cancel>1</cancel>")
        default: throw HostError.invalidResponse
        }
    }
    private func xml(_ body: String) -> Data { Data("<root status_code=\"200\">\(body)</root>".utf8) }
}

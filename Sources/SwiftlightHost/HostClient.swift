import Foundation

public actor HostClient {
    public let address: HostAddress
    private let expectedHostID: String?
    private let identityStore: any HostIdentityProviding
    private let transport: any HostHTTPTransport
    private var cachedInfo: HostInfo?
    private var pairing = false

    public init(address: HostAddress, hostID: String? = nil, identityStore: HostIdentityStore = .shared) {
        self.address = address; expectedHostID = hostID; self.identityStore = identityStore; transport = URLSessionHostTransport()
    }
    init(address: HostAddress, hostID: String? = nil, identityStore: any HostIdentityProviding, transport: any HostHTTPTransport) {
        self.address = address; expectedHostID = hostID; self.identityStore = identityStore; self.transport = transport
    }
    private var pinKeys: [String] { [address.description] + [expectedHostID, cachedInfo?.id].compactMap { $0 } }
    private func pin() async throws -> Data? {
        for key in pinKeys { if let result = try await identityStore.pin(key) { return result } }; return nil
    }
    private func request(_ path: String, items: [URLQueryItem] = [], secure: Bool, pin: Data? = nil,
                         httpsPort: Int? = nil, timeout: TimeInterval = 10) async throws -> HostXML {
        try HostXML(data: await requestData(path, items: items, secure: secure, pin: pin, httpsPort: httpsPort, timeout: timeout))
    }
    private func requestData(_ path: String, items: [URLQueryItem] = [], secure: Bool, pin: Data? = nil,
                             httpsPort: Int? = nil, timeout: TimeInterval = 10) async throws -> Data {
        try Task.checkCancellation()
        let identity = try await identityStore.identity()
        let query = [URLQueryItem(name: "uniqueid", value: identity.uniqueID), URLQueryItem(name: "uuid", value: UUID().uuidString)] + items
        let url = try address.url(path: path, secure: secure, httpsPort: httpsPort ?? cachedInfo?.httpsPort, query: query)
        return try await transport.fetch(HostHTTPRequest(url: url, timeout: timeout), identity: identity, pin: pin)
    }
    public func serverInfo() async throws -> HostInfo {
        var savedPin = try await pin()
        // The bootstrap port may differ from the standard offset. Discover it over HTTP,
        // then authenticate the response again over pinned TLS before returning paired data.
        if cachedInfo == nil {
            let bootstrap = try await request("serverinfo", secure: false).serverInfo(defaultHTTPSPort: address.httpPort - 5, authenticated: false)
            if let expectedHostID, bootstrap.id != expectedHostID { throw HostError.identityChanged }
            cachedInfo = bootstrap
            // A new address can resolve to a previously paired host. Its claimed ID
            // selects a candidate pin, which must still authenticate the TLS peer.
            if savedPin == nil { savedPin = try await pin() }
        }
        let response = try await request("serverinfo", secure: savedPin != nil, pin: savedPin)
        // Wire PairStatus cannot establish client trust. HTTP responses remain unpaired
        // until a locally pinned TLS connection authenticates the host and client.
        let info = try response.serverInfo(defaultHTTPSPort: address.httpPort - 5, authenticated: savedPin != nil)
        if let expectedHostID, info.id != expectedHostID { throw HostError.identityChanged }
        cachedInfo = info; return info
    }
    public func pair(pin: String, clientName: String = "Swiftlight") async throws -> HostInfo {
        guard pin.utf8.count == 4, pin.utf8.allSatisfy({ (48...57).contains($0) }) else { throw HostError.invalidPIN }
        return try await performPair(pin: pin, credential: nil, clientName: clientName)
    }
    public func pair(credential: ApolloPairingCredential, clientName: String = "Swiftlight") async throws -> HostInfo {
        guard credential.address == address else { throw HostError.invalidAddress }
        return try await performPair(pin: credential.otp, credential: credential, clientName: clientName)
    }
    private func performPair(pin: String, credential: ApolloPairingCredential?, clientName: String) async throws -> HostInfo {
        guard !pairing else { throw HostError.pairingInProgress }
        pairing = true; defer { pairing = false }
        // A trust change always requires explicit forget/unpair first.
        if try await self.pin() != nil {
            let info = try await serverInfo()
            guard info.isPaired else { throw HostError.pairingFailed }
            return info
        }
        let info = try await serverInfo()
        guard (Int(info.appVersion.split(separator: ".").first ?? "") ?? 0) >= 7 else { throw HostError.unsupportedHost }
        let identity = try await identityStore.identity()
        let salt = try PairingCrypto.random(16)
        let key = Data(PairingCrypto.sha256(salt + Data(pin.utf8)).prefix(16))
        let name = String(clientName.prefix(128))
        let common = [URLQueryItem(name: "devicename", value: name), URLQueryItem(name: "updateState", value: "1")]
        var bootstrap = common + [URLQueryItem(name: "phrase", value: "getservercert"), URLQueryItem(name: "salt", value: salt.hex), URLQueryItem(name: "clientcert", value: identity.certificate.hex)]
        if let credential { bootstrap.append(URLQueryItem(name: "otpauth", value: credential.authentication(salt: salt))) }
        do {
            let certificateResponse: HostXML
            do { certificateResponse = try await request("pair", items: bootstrap, secure: false, timeout: 120) }
            catch HostError.hostStatus(503) where credential != nil { throw HostError.credentialUnavailable }
            try certificateResponse.requirePaired()
            guard let plainCert = certificateResponse.fields["plaincert"], !plainCert.isEmpty else { throw HostError.pairingInProgress }
            let certificate = try Data(strictHex: plainCert), der = try PairingCrypto.der(certificate)
            let randomChallenge = try PairingCrypto.random(16)
            let encrypted = try PairingCrypto.aes(randomChallenge, key: key, encrypt: true)
            let challenge = try await request("pair", items: common + [URLQueryItem(name: "clientchallenge", value: encrypted.hex)], secure: false)
            try challenge.requirePaired()
            let encryptedResponse = try Data(strictHex: challenge.required("challengeresponse"))
            let response = try PairingCrypto.aes(encryptedResponse, key: key, encrypt: false)
            guard response.count == 48 else { throw HostError.invalidResponse }
            let serverHash = Data(response.prefix(32)), serverChallenge = Data(response.suffix(16))
            let clientSecret = try PairingCrypto.random(16)
            let clientHash = try PairingCrypto.sha256(serverChallenge + PairingCrypto.signature(identity.certificate) + clientSecret)
            let encryptedHash = try PairingCrypto.aes(clientHash, key: key, encrypt: true)
            let secretResponse = try await request("pair", items: common + [URLQueryItem(name: "serverchallengeresp", value: encryptedHash.hex)], secure: false)
            try secretResponse.requirePaired()
            let secret = try Data(strictHex: secretResponse.required("pairingsecret"))
            guard secret.count > 16 else { throw HostError.invalidResponse }
            let serverSecret = Data(secret.prefix(16)), serverSignature = Data(secret.dropFirst(16))
            guard PairingCrypto.verify(serverSecret, signature: serverSignature, certificate: certificate) else { throw HostError.cryptoFailure }
            let expectedHash = try PairingCrypto.sha256(randomChallenge + PairingCrypto.signature(certificate) + serverSecret)
            guard PairingCrypto.constantTimeEqual(expectedHash, serverHash) else { throw credential == nil ? HostError.incorrectPIN : HostError.credentialRejected }
            let clientProof = try clientSecret + PairingCrypto.sign(clientSecret, key: identity.privateKey)
            let paired = try await request("pair", items: common + [URLQueryItem(name: "clientpairingsecret", value: clientProof.hex)], secure: false)
            try paired.requirePaired()
            let challengeResult = try await request("pair", items: common + [URLQueryItem(name: "phrase", value: "pairchallenge")], secure: true, pin: der)
            try challengeResult.requirePaired()
            let authenticatedInfo = try await request("serverinfo", secure: true, pin: der).serverInfo(defaultHTTPSPort: info.httpsPort, authenticated: true)
            guard authenticatedInfo.id == info.id else { throw HostError.identityChanged }
            guard authenticatedInfo.isPaired else { throw HostError.pairingFailed }
            try Task.checkCancellation()
            try await identityStore.savePin(der, keys: [address.description, info.id])
            cachedInfo = authenticatedInfo
            return authenticatedInfo
        } catch {
            // Cleanup uses its own task so cancellation also clears the pending host
            // challenge. It is bounded and never changes an existing trusted pairing.
            let transport = self.transport, address = self.address
            let cleanup = Task {
                let url = try address.url(path: "unpair", secure: false, query: [URLQueryItem(name: "uniqueid", value: identity.uniqueID), URLQueryItem(name: "uuid", value: UUID().uuidString)])
                _ = try await transport.fetch(HostHTTPRequest(url: url, timeout: 3), identity: identity, pin: nil)
            }
            _ = try? await cleanup.value
            throw error
        }
    }
    public func apps() async throws -> [RemoteApp] {
        guard let pin = try await pin() else { throw HostError.notPaired }
        let info = try await serverInfo()
        if let permissions = info.permissions, permissions & 0x07000000 == 0 { throw HostError.permissionDenied }
        return try await request("applist", secure: true, pin: pin).apps()
    }
    /// Original encoded cover bytes from the paired host. The caller owns a bounded
    /// cache and thumbnail sizing; an unavailable cover need not fail the library.
    /// Covers use the same exact-certificate mutual TLS policy as the app list.
    public func artwork(appID: Int) async throws -> Data {
        guard appID > 0, appID <= Int(Int32.max) else { throw HostError.invalidResponse }
        try Task.checkCancellation()
        guard let savedPin = try await pin() else { throw HostError.notPaired }
        // Discover a custom HTTPS port and authenticate once if this client has not
        // loaded serverinfo yet. Do not repeat those requests for every library tile.
        if cachedInfo == nil { _ = try await serverInfo() }
        guard cachedInfo?.isPaired == true else { throw HostError.notPaired }
        let data = try await requestData("appasset", items: [
            URLQueryItem(name: "appid", value: String(appID)),
            URLQueryItem(name: "AssetType", value: "2"), URLQueryItem(name: "AssetIdx", value: "0")
        ], secure: true, pin: savedPin)
        try Task.checkCancellation()
        try HostArtwork.validate(data)
        try Task.checkCancellation()
        return data
    }
    public func launch(_ request: StreamLaunchRequest) async throws -> StreamLaunchResponse { try await start(request, resume: false) }
    public func resume(_ request: StreamLaunchRequest) async throws -> StreamLaunchResponse { try await start(request, resume: true) }
    public func launchOrResume(_ request: StreamLaunchRequest) async throws -> StreamLaunchResponse { try await start(request, resume: nil) }
    /// Revalidate confirmation against the app currently on the host. A changed
    /// app needs a new confirmation, and a failed quit must never proceed to launch.
    public func prepareApplication(_ appID: Int, quitting expectedAppID: Int? = nil) async throws -> HostInfo {
        var info = try await serverInfo()
        guard info.isPaired else { throw HostError.notPaired }
        if info.currentAppID > 0 && info.currentAppID != appID {
            guard info.currentAppID == expectedAppID else { throw RunningApplicationConflict(hostInfo: info) }
            try await quitApplication(expectedAppID: info.currentAppID)
            info = try await serverInfo()
            if info.currentAppID > 0 && info.currentAppID != appID { throw RunningApplicationConflict(hostInfo: info) }
        }
        try Task.checkCancellation()
        return info
    }
    private func start(_ launch: StreamLaunchRequest, resume requestedResume: Bool?) async throws -> StreamLaunchResponse {
        guard let pin = try await pin() else { throw HostError.notPaired }
        let info = try await serverInfo()
        guard info.currentAppID == 0 || info.currentAppID == launch.appID else { throw RunningApplicationConflict(hostInfo: info) }
        let resume = requestedResume ?? (info.currentAppID == launch.appID)
        if let permissions = info.permissions {
            let needed: UInt32 = (resume || info.currentAppID == launch.appID) ? 0x06000000 : 0x04000000
            guard permissions & needed != 0 else { throw HostError.permissionDenied }
        }
        var values = ["appid": String(launch.appID), "mode": "\(launch.width)x\(launch.height)x\(launch.fps)", "additionalStates": "1", "sops": "1",
                      "rikey": launch.inputKey.hex, "rikeyid": String(Int32(bitPattern: launch.inputKeyID)), "localAudioPlayMode": launch.playAudioOnHost ? "1" : "0",
                      "surroundAudioInfo": String(launch.surroundAudioInfo), "remoteControllersBitmap": String(launch.controllerMask), "gcmap": String(launch.controllerMask), "gcpersist": "0"]
        if launch.hdr {
            values.merge(["hdrMode": "1", "clientHdrCapVersion": "0", "clientHdrCapSupportedFlagsInUint32": "0", "clientHdrCapMetaDataId": "NV_STATIC_METADATA_TYPE_1", "clientHdrCapDisplayData": "0x0x0x0x0x0x0x0x0x0x0"], uniquingKeysWith: { _, new in new })
        }
        for item in launch.additionalQuery {
            guard values[item.name] == nil, !["uniqueid", "uuid"].contains(item.name), let value = item.value else { throw HostError.invalidResponse }
            values[item.name] = value
        }
        let response = try await request(resume ? "resume" : "launch", items: values.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }, secure: true, pin: pin, timeout: 30)
        let session = try response.required("sessionUrl0")
        guard let url = URLComponents(string: session), ["rtsp", "rtspenc"].contains(url.scheme ?? ""), url.host != nil else { throw HostError.launchFailed }
        return StreamLaunchResponse(sessionURL: session, hostInfo: info)
    }
    /// Only explicit Quit sends /cancel. Local stream disconnect never calls this.
    public func quitApplication(expectedAppID: Int? = nil) async throws {
        guard let pin = try await pin() else { throw HostError.notPaired }
        let info = try await serverInfo()
        guard info.currentAppID > 0 else { return }
        if let expectedAppID, info.currentAppID != expectedAppID { throw RunningApplicationConflict(hostInfo: info) }
        _ = try await request("cancel", secure: true, pin: pin, timeout: 30)
        guard try await serverInfo().currentAppID == 0 else { throw HostError.permissionDenied }
    }
    public func unpair() async throws {
        guard !pairing else { throw HostError.pairingInProgress }
        _ = try await request("unpair", secure: false)
        try await forgetPairing()
    }
    /// Local removal deliberately does not terminate an app or use a changed certificate.
    public func forgetPairing() async throws {
        guard !pairing else { throw HostError.pairingInProgress }
        try await identityStore.removePins(pinKeys); cachedInfo = nil
    }
}

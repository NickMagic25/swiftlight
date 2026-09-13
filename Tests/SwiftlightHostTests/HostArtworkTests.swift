import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import SwiftlightHost

@Test func artworkUsesPinnedHTTPSContractAndCachedCustomPort() async throws {
    let address = try HostAddress("[2001:db8::7]:48089")
    let vault = try ArtworkVault(paired: true), peer = try ArtworkPeer()
    let client = HostClient(address: address, hostID: "cover-fixture", identityStore: vault, transport: peer)
    let first = try await client.artwork(appID: 17)
    #expect(first == peer.image)
    #expect(try await client.artwork(appID: 18) == first)
    let requests = await peer.requests
    #expect(requests.map { $0.url.scheme! + ":" + $0.url.path } ==
        ["http:/serverinfo", "https:/serverinfo", "https:/appasset", "https:/appasset"])
    for (index, request) in requests.suffix(2).enumerated() {
        let parts = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(parts.port == 48184)
        #expect(normalizedTLSHost(parts.host ?? "") == "2001:db8::7")
        #expect(query["appid"] == String(17 + index))
        #expect(query["AssetType"] == "2" && query["AssetIdx"] == "0")
        #expect(query["uniqueid"] == vault.envelope.uniqueID)
        #expect(UUID(uuidString: query["uuid"] ?? "") != nil)
        #expect(Set(query.keys) == ["uniqueid", "uuid", "appid", "AssetType", "AssetIdx"])
    }
}

@Test func artworkRejectsUnpairedAndInvalidAppIDsBeforeNetwork() async throws {
    let vault = try ArtworkVault(paired: false), peer = try ArtworkPeer()
    let client = try HostClient(address: HostAddress("fixture.invalid"), identityStore: vault, transport: peer)
    await #expect(throws: HostError.notPaired) { try await client.artwork(appID: 17) }
    for id in [0, -1, Int.max] {
        await #expect(throws: HostError.invalidResponse) { try await client.artwork(appID: id) }
    }
    #expect(await peer.requests.isEmpty)
}

@Test func artworkFailuresNeverRetryOverHTTP() async throws {
    for error in [HostError.certificateChanged, .permissionDenied, .hostStatus(404), .timeout] {
        let vault = try ArtworkVault(paired: true), peer = try ArtworkPeer(error: error)
        let client = try HostClient(address: HostAddress("fixture.invalid"), hostID: "cover-fixture", identityStore: vault, transport: peer)
        await #expect(throws: error) { try await client.artwork(appID: 17) }
        let requests = await peer.requests.filter { $0.url.path == "/appasset" }
        #expect(requests.count == 1)
        #expect(requests.first?.url.scheme == "https")
    }
}

@Test func artworkCancellationDoesNotReturnAnImageOrRetry() async throws {
    let vault = try ArtworkVault(paired: true), peer = try ArtworkPeer(waitForCancellation: true)
    let client = try HostClient(address: HostAddress("fixture.invalid"), hostID: "cover-fixture", identityStore: vault, transport: peer)
    let task = Task { try await client.artwork(appID: 17) }
    await peer.waitUntilArtworkStarts()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await peer.requests.filter { $0.url.path == "/appasset" }.count == 1)
}

@Test func artworkValidationAcceptsRasterAndRejectsMalformedOrOversizedContent() throws {
    for type in [UTType.png, .jpeg] { try HostArtwork.validate(makeCover(type: type)) }
    let image = try makeCover()
    for invalid in [Data(), Data("<root status_code=\"404\"/>".utf8), Data(image.prefix(image.count / 2)),
                    Data(repeating: 0, count: HostHTTPRequest.maximumResponseBytes + 1),
                    try makeCover(width: 4097, height: 1), try makeCover(width: 4096, height: 2049),
                    try makeCover(type: .gif, frames: 2)] {
        #expect(throws: HostError.invalidArtwork) { try HostArtwork.validate(invalid) }
    }
}

@Test func artworkRequestsAreRejectedAfterPairingWasForgotten() async throws {
    let vault = try ArtworkVault(paired: true), peer = try ArtworkPeer()
    let client = try HostClient(address: HostAddress("fixture.invalid"), hostID: "cover-fixture", identityStore: vault, transport: peer)
    _ = try await client.artwork(appID: 17)
    try await client.forgetPairing()
    await #expect(throws: HostError.notPaired) { try await client.artwork(appID: 18) }
    #expect(await peer.requests.filter { $0.url.path == "/appasset" }.count == 1)
}

private func makeCover(width: Int = 8, height: Int = 12, type: UTType = .png, frames: Int = 1) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage()), data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, frames, nil))
    for _ in 0..<frames { CGImageDestinationAddImage(destination, image, nil) }
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private actor ArtworkVault: HostIdentityProviding {
    nonisolated let envelope: HostIdentityEnvelope
    private var paired: Bool
    init(paired: Bool) throws { envelope = try HostIdentityEnvelope.generate(); self.paired = paired }
    func identity() -> HostIdentityEnvelope { envelope }
    func pin(_ key: String) -> Data? { paired && key == "cover-fixture" ? Data([0x41, 0x52, 0x54]) : nil }
    func savePin(_ certificate: Data, keys: [String]) { paired = true }
    func removePins(_ keys: [String]) { paired = false }
}

private actor ArtworkPeer: HostHTTPTransport {
    nonisolated let image: Data
    let error: HostError?
    let waitForCancellation: Bool
    var requests: [HostHTTPRequest] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(error: HostError? = nil, waitForCancellation: Bool = false) throws {
        image = try makeCover(); self.error = error; self.waitForCancellation = waitForCancellation
    }
    func waitUntilArtworkStarts() async {
        if requests.contains(where: { $0.url.path == "/appasset" }) { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func fetch(_ request: HostHTTPRequest, identity: HostIdentityEnvelope, pin: Data?) async throws -> Data {
        requests.append(request)
        if request.url.scheme == "https" { #expect(pin == Data([0x41, 0x52, 0x54])) }
        if request.url.path == "/serverinfo" {
            return Data("<root status_code=\"200\"><uniqueid>cover-fixture</uniqueid><hostname>Cover Fixture</hostname><appversion>7.1.0.0</appversion><HttpsPort>48184</HttpsPort><PairStatus>1</PairStatus></root>".utf8)
        }
        #expect(request.url.path == "/appasset")
        waiters.forEach { $0.resume() }; waiters.removeAll()
        if let error { throw error }
        if waitForCancellation { try await Task.sleep(for: .seconds(30)) }
        return image
    }
}

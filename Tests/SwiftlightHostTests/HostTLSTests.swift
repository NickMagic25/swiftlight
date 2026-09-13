import Foundation
import Network
import Security
import Testing
@testable import SwiftlightHost

@Test(.enabled(if: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15))
func asyncByteTransportUsesPinnedMutualTLS() async throws {
    // Fresh identities are imported into memory only; no Keychain or external host.
    guard #available(macOS 15, iOS 18, tvOS 18, *) else { return }
    let serverIdentity = try HostIdentityEnvelope.generate(), clientIdentity = try HostIdentityEnvelope.generate()
    let server = try LocalMutualTLSPeer(identity: serverIdentity, expectedClient: PairingCrypto.der(clientIdentity.certificate))
    let port = try await server.start()
    defer { server.stop() }
    let request = HostHTTPRequest(url: URL(string: "https://127.0.0.1:\(port)/serverinfo")!, timeout: 5)
    let response = try await URLSessionHostTransport().fetch(request, identity: clientIdentity, pin: PairingCrypto.der(serverIdentity.certificate))
    #expect(response == Data("mutual TLS verified".utf8))
    await #expect(throws: HostError.certificateChanged) {
        try await URLSessionHostTransport().fetch(request, identity: clientIdentity, pin: PairingCrypto.der(clientIdentity.certificate))
    }
}

/// A loopback-only TLS server using ephemeral Security identities and an exact
/// client-certificate check. This exercises URLSession delegate routing, which an
/// in-process HostHTTPTransport protocol fixture cannot validate.
private final class LocalMutualTLSPeer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "net.swiftlight.tests.mutual-tls")
    private let listener: NWListener
    // Access only on queue.
    private var connections: [NWConnection] = []

    init(identity: HostIdentityEnvelope, expectedClient: Data) throws {
        let tls = NWProtocolTLS.Options()
        guard let localIdentity = sec_identity_create(try identity.tlsIdentity()) else { throw HostError.cryptoFailure }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, localIdentity)
        sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, true)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let trustRef = sec_trust_copy_ref(trust).takeRetainedValue()
            let actual = (SecTrustCopyCertificateChain(trustRef) as? [SecCertificate])?.first
            complete(actual.map { SecCertificateCopyData($0) as Data == expectedClient } ?? false)
        }, queue)
        let parameters = NWParameters(tls: tls)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connections.append(connection)
            connection.stateUpdateHandler = { state in
                guard case .ready = state else { return }
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, error in
                    guard error == nil else { connection.cancel(); return }
                    let body = "mutual TLS verified"
                    let reply = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                    connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            connection.start(queue: queue)
        }
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    if let port = listener.port { continuation.resume(returning: port.rawValue) }
                    else { continuation.resume(throwing: HostError.connectionFailed) }
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            listener.cancel()
            connections.forEach { $0.stateUpdateHandler = nil; $0.cancel() }
            connections.removeAll()
        }
    }
}

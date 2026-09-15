import Foundation
import Security

struct HostHTTPRequest: Sendable {
    static let maximumResponseBytes = 4 * 1024 * 1024
    let url: URL
    let timeout: TimeInterval
}
func normalizedTLSHost(_ host: String) -> String {
    var result = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    result = (result.removingPercentEncoding ?? result).lowercased()
    if result.hasSuffix(".") { result.removeLast() }
    return result
}
protocol HostHTTPTransport: Sendable {
    func fetch(_ request: HostHTTPRequest, identity: HostIdentityEnvelope, pin: Data?) async throws -> Data
}

struct URLSessionHostTransport: HostHTTPTransport {
    func fetch(_ request: HostHTTPRequest, identity: HostIdentityEnvelope, pin: Data?) async throws -> Data {
        let secure = request.url.scheme == "https"
        if secure && pin == nil { throw HostError.notPaired }
        let delegate = HostSessionDelegate(host: request.url.host ?? "", port: request.url.port ?? 0,
                                           pin: pin, identity: secure ? try identity.tlsIdentity() : nil)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = request.timeout; configuration.timeoutIntervalForResource = request.timeout
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: request.timeout)
        urlRequest.httpMethod = "GET"; urlRequest.setValue("Swiftlight/1", forHTTPHeaderField: "User-Agent")
        do {
            let (bytes, response) = try await session.bytes(for: urlRequest, delegate: delegate)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw HostError.invalidResponse }
            if http.statusCode == 401 || http.statusCode == 403 { throw HostError.permissionDenied }
            guard http.statusCode == 200 else { throw HostError.hostStatus(http.statusCode) }
            let maximum = HostHTTPRequest.maximumResponseBytes
            guard response.expectedContentLength <= Int64(maximum) else { throw HostError.invalidResponse }
            var data = Data()
            if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
            for try await byte in bytes {
                guard data.count < maximum else { throw HostError.invalidResponse }
                data.append(byte)
            }
            try Task.checkCancellation()
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as HostError { throw error }
        catch let error as URLError {
            if Task.isCancelled { throw CancellationError() }
            if delegate.certificateRejected { throw HostError.certificateChanged }
            if error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut { throw HostError.timeout }
            throw HostError.networkFailure(error.errorCode)
        } catch { throw HostError.connectionFailed }
    }
}

/// The pairing protocol establishes an exact leaf-certificate pin through its signed
/// challenge. Self-signed acceptance is scoped to that one host/port and certificate.
private final class HostSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let host: String, port: Int, pin: Data?, identity: SecIdentity?
    private let lock = NSLock()
    private var rejected = false
    var certificateRejected: Bool { lock.lock(); defer { lock.unlock() }; return rejected }
    init(host: String, port: Int, pin: Data?, identity: SecIdentity?) {
        self.host = host; self.port = port; self.pin = pin; self.identity = identity
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Async byte transfers deliver authentication through their task delegate.
        // Keep the same exact host/port/pin policy for both callback paths.
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard normalizedTLSHost(space.host) == normalizedTLSHost(host), space.port == port, challenge.previousFailureCount == 0 else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let pin, let trust = space.serverTrust,
                  let certificate = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
                  PairingCrypto.constantTimeEqual(SecCertificateCopyData(certificate) as Data, pin) else {
                lock.lock(); rejected = true; lock.unlock()
                completionHandler(.cancelAuthenticationChallenge, nil); return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        case NSURLAuthenticationMethodClientCertificate:
            guard let identity else { completionHandler(.cancelAuthenticationChallenge, nil); return }
            completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
        default: completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Pairing requests contain credential material in the established query protocol.
        // Never forward them, even to another path on the same server.
        completionHandler(nil)
    }
}

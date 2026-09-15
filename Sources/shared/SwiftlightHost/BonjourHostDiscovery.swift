import Foundation
import Combine

public struct DiscoveredHost: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let address: HostAddress
}

/// Main-run-loop Bonjour resolution preserves the advertised custom HTTP port.
@MainActor public final class BonjourHostDiscovery: NSObject, ObservableObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    @Published public private(set) var hosts: [DiscoveredHost] = []
    @Published public private(set) var errorMessage: String?
    private var browser: NetServiceBrowser?
    private var services: [String: NetService] = [:]
    public override init() { super.init() }
    public func start() {
        guard browser == nil else { return }
        errorMessage = nil
        let browser = NetServiceBrowser(); browser.delegate = self; self.browser = browser
        browser.searchForServices(ofType: "_nvstream._tcp.", inDomain: "local.")
    }
    public func stop() {
        browser?.stop(); browser?.delegate = nil; browser = nil
        for service in services.values { service.stop(); service.delegate = nil }
        services.removeAll(); hosts.removeAll()
    }
    private func key(_ service: NetService) -> String { service.name + "." + service.type + service.domain }
    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let key = key(service); services[key] = service; service.delegate = self; service.resolve(withTimeout: 5)
    }
    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let key = key(service); services.removeValue(forKey: key)?.stop(); hosts.removeAll { $0.id == key }
    }
    public func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        errorMessage = "Local discovery is unavailable. Check Local Network permission, or add the host by address."
    }
    public func netServiceDidResolveAddress(_ sender: NetService) {
        guard let hostname = sender.hostName, let address = try? HostAddress(host: hostname, httpPort: sender.port) else { return }
        let id = key(sender); hosts.removeAll { $0.id == id }
        hosts.append(DiscoveredHost(id: id, name: sender.name, address: address))
        hosts.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        services.removeValue(forKey: key(sender))
    }
}

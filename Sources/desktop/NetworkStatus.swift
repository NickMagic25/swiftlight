#if os(macOS)
import Foundation
import Network
import Combine

@MainActor final class NetworkStatus: ObservableObject {
    @Published var description = "Checking network…"
    @Published var available = true
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "net.edrisil.swiftlight.network")
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            let kind = path.usesInterfaceType(.wiredEthernet) ? "Ethernet" : path.usesInterfaceType(.wifi) ? "Wi-Fi" : path.usesInterfaceType(.cellular) ? "Cellular" : "Other interface"
            let message = available ? ([kind, path.isExpensive ? "expensive" : nil, path.isConstrained ? "constrained" : nil,
                path.supportsIPv6 ? "IPv6 available" : nil].compactMap { $0 }.joined(separator: " · ")) : "No network path"
            Task { @MainActor [weak self] in self?.available = available; self?.description = message }
        }
        monitor.start(queue: queue)
    }
    deinit { monitor.cancel() }
}

#endif

import Foundation
import Network

public final class NetworkMonitor: @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.karen.remote.companion.networkmonitor")
    public var onStatusChange: ((Bool) -> Void)?

    private(set) public var isConnected: Bool = true

    public init() {
        self.monitor = NWPathMonitor()
    }

    public func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let reachable = (path.status == .satisfied)
            if self.isConnected != reachable {
                self.isConnected = reachable
                DispatchQueue.main.async {
                    self.onStatusChange?(reachable)
                }
            }
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        monitor.cancel()
    }
}


import Foundation
import AppKit

public final class SleepWakeMonitor: @unchecked Sendable {
    public var onSleep: (() -> Void)?
    public var onWake: (() -> Void)?

    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    public init() {}

    public func start() {
        let center = NSWorkspace.shared.notificationCenter

        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onSleep?()
        }

        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Small delay to let network interface negotiate connection
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self?.onWake?()
            }
        }
    }

    public func stop() {
        let center = NSWorkspace.shared.notificationCenter
        if let obs = sleepObserver {
            center.removeObserver(obs)
            sleepObserver = nil
        }
        if let obs = wakeObserver {
            center.removeObserver(obs)
            wakeObserver = nil
        }
    }

    deinit {
        stop()
    }
}


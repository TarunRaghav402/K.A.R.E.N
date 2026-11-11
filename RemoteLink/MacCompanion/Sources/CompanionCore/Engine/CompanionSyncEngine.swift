import Foundation

@MainActor
public protocol CompanionSyncEngineDelegate: AnyObject {
    func syncEngineStateDidChange(_ state: ConnectionState)
    func syncEnginePendingCountDidChange(_ count: Int)
    func syncEngineLastSyncDidChange(_ date: Date?)
    func syncEngineDidReceiveResponse(_ record: NotificationRequestRecord)
}

public final class CompanionSyncEngine: @unchecked Sendable {
    public weak var delegate: CompanionSyncEngineDelegate?

    public private(set) var state: ConnectionState = .offline {
        didSet {
            if oldValue != state {
                let s = state
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.syncEngineStateDidChange(s)
                }
            }
        }
    }

    public private(set) var pendingCount: Int = 0 {
        didSet {
            if oldValue != pendingCount {
                let c = pendingCount
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.syncEnginePendingCountDidChange(c)
                }
            }
        }
    }

    public private(set) var lastSyncDate: Date? {
        didSet {
            let d = lastSyncDate
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.syncEngineLastSyncDidChange(d)
            }
        }
    }

    private let configStore: ConfigStore
    private let apiClient: CloudAPIClient
    private let journal: ResponseJournal
    private let networkMonitor: NetworkMonitor
    private let sleepWakeMonitor: SleepWakeMonitor

    private var syncTimer: Timer?
    private var isSyncing: Bool = false
    private var consecutiveErrors: Int = 0

    public init(
        configStore: ConfigStore = .shared,
        apiClient: CloudAPIClient = CloudAPIClient(),
        journal: ResponseJournal = .shared
    ) {
        self.configStore = configStore
        self.apiClient = apiClient
        self.journal = journal
        self.networkMonitor = NetworkMonitor()
        self.sleepWakeMonitor = SleepWakeMonitor()

        setupMonitors()
    }

    private func setupMonitors() {
        networkMonitor.onStatusChange = { [weak self] isConnected in
            guard let self = self else { return }
            if isConnected {
                self.state = .reconnecting
                Task { await self.performSync() }
            } else {
                self.state = .offline
            }
        }

        sleepWakeMonitor.onSleep = { [weak self] in
            guard let self = self else { return }
            self.stopTimer()
            self.state = .offline
        }

        sleepWakeMonitor.onWake = { [weak self] in
            guard let self = self else { return }
            self.state = .reconnecting
            self.startTimer()
            Task { await self.performSync() }
        }
    }

    public func start() {
        networkMonitor.start()
        sleepWakeMonitor.start()
        startTimer()
        Task { await self.performSync() }
    }

    public func stop() {
        stopTimer()
        networkMonitor.stop()
        sleepWakeMonitor.stop()
        state = .offline
    }

    private func startTimer() {
        stopTimer()
        let interval = max(configStore.load().pollIntervalSeconds, 5.0)
        DispatchQueue.main.async { [weak self] in
            self?.syncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                Task { await self.performSync() }
            }
        }
    }

    private func stopTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.syncTimer?.invalidate()
            self?.syncTimer = nil
        }
    }

    public func createPairingSession() async throws -> PairingSessionRecord {
        let config = configStore.load()
        return try await apiClient.createPairingSession(config: config)
    }

    public func syncNow() {
        Task { await self.performSync() }
    }

    public func performSync() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let config = configStore.load()

        do {
            let snapshot = try await apiClient.fetchSyncSnapshot(config: config)
            
            // Successfully connected to Cloudflare D1
            consecutiveErrors = 0
            state = .connected
            lastSyncDate = Date()
            pendingCount = snapshot.pendingRequests.count

            // Process any responses queued while offline or during wait
            for responseRecord in snapshot.unprocessedResponses {
                // Record in local persistent journal
                if let outcome = responseRecord.outcome {
                    let entry = JournalEntry(
                        timestamp: responseRecord.respondedAt ?? Date().timeIntervalSince1970,
                        requestId: responseRecord.requestId,
                        title: responseRecord.title,
                        outcome: outcome,
                        replyText: responseRecord.replyText,
                        responderDeviceId: responseRecord.responderDeviceId
                    )
                    journal.append(entry: entry)
                }

                // Notify delegate on main thread
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.syncEngineDidReceiveResponse(responseRecord)
                }

                // Acknowledge to Cloudflare D1 to mark as COMPLETED
                do {
                    try await apiClient.acknowledgeResponse(config: config, requestId: responseRecord.requestId)
                } catch {
                    // Will be retried on next sync
                }
            }

        } catch {
            consecutiveErrors += 1
            if consecutiveErrors > 2 {
                state = .offline
            } else {
                state = .reconnecting
            }
        }
    }

    public func sendNotification(
        title: String,
        message: String,
        details: String? = nil,
        actions: [String] = ["APPROVE", "DENY", "REPLY"],
        timeoutSeconds: Double = 300
    ) async throws -> NotificationRequestRecord {
        let config = configStore.load()
        let record = try await apiClient.sendNotificationRequest(
            config: config,
            title: title,
            message: message,
            details: details,
            actions: actions,
            timeoutSeconds: timeoutSeconds,
            idempotencyKey: UUID().uuidString
        )
        // Refresh sync right after sending
        Task { await self.performSync() }
        return record
    }
}

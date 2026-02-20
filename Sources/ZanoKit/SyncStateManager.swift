import Combine
import Foundation
import HsToolKit

class SyncStateManager {
    static let storeBlocksCount: UInt64 = 2000
    static let connectTimeout: TimeInterval = 30

    private var cancellables = Set<AnyCancellable>()
    private var reachabilityManager: ReachabilityManager
    private let logger: Logger?
    private let api: ZanoWalletAPI
    private var isRunning = false
    private var walletId: Int64?

    private let queue = DispatchQueue(label: "io.horizontalsystems.zano_kit.core_state_queue", qos: .userInitiated)

    private var connectStartTime: Date?
    private var restoreHeight: UInt64
    private var lastStoredBlockHeight: UInt64 = 0
    private var daemonHeight: UInt64 = 0
    private(set) var walletHeight: UInt64 = 0
    private(set) var blockHeights: (UInt64, UInt64)?
    private var isDaemonConnected: Bool = false
    private(set) var isInLongRefresh: Bool = false

    var onSyncStateChanged: (() -> Void)?

    var state: WalletState = .notSynced(error: WalletStateError.notStarted) {
        didSet {
            if oldValue != state {
                onSyncStateChanged?()
            }
        }
    }

    var chunkOfBlocksSynced: Bool {
        if lastStoredBlockHeight < restoreHeight {
            return false
        }
        return lastStoredBlockHeight <= walletHeight && walletHeight - lastStoredBlockHeight >= Self.storeBlocksCount
    }

    init(api: ZanoWalletAPI, logger: Logger?, restoreHeight: UInt64, reachabilityManager: ReachabilityManager) {
        self.api = api
        self.logger = logger
        self.reachabilityManager = reachabilityManager
        self.restoreHeight = restoreHeight

        reachabilityManager.$isReachable
            .receive(on: queue)
            .sink { [weak self] isReachable in
                self?.state = .idle(daemonReachable: isReachable)
            }
            .store(in: &cancellables)
    }

    private func evaluateState() -> WalletState {
        guard reachabilityManager.isReachable else {
            return .idle(daemonReachable: false)
        }

        if !isDaemonConnected {
            if let connectStartTime, Date().timeIntervalSince(connectStartTime) > Self.connectTimeout {
                return .notSynced(error: .statusError("Connection timed out"))
            }
            return .connecting(waiting: false)
        }

        guard daemonHeight > 0 else {
            return .connecting(waiting: false)
        }

        // Check if synced (allow 1-2 blocks difference since daemon keeps getting new blocks)
        if walletHeight + 2 >= daemonHeight && !isInLongRefresh {
            return .synced
        }

        // Calculate sync progress
        let effectiveRestoreHeight = min(restoreHeight, daemonHeight)
        let numberOfBlocksToSync = Int(daemonHeight - effectiveRestoreHeight)
        let numberOfBlocksSynced = Int(max(0, Int64(walletHeight) - Int64(effectiveRestoreHeight)))

        if numberOfBlocksToSync <= 0 {
            return .synced
        }

        blockHeights = (walletHeight, daemonHeight)
        let progress = min(100, numberOfBlocksSynced * 100 / numberOfBlocksToSync)
        return .syncing(progress: progress, remainingBlocksCount: max(0, numberOfBlocksToSync - numberOfBlocksSynced))
    }

    private func checkSyncState() {
        guard let wid = walletId else { return }

        // Call get_wallet_status to get sync info
        guard let resultJson = api.getWalletStatus(walletId: wid),
              let data = resultJson.data(using: .utf8),
              let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger?.error("Failed to get wallet status")
            scheduleNextCheck()
            return
        }

        // Parse status response
        // {
        //   "current_daemon_height": 2809788,
        //   "current_wallet_height": 2282031,
        //   "is_daemon_connected": true,
        //   "is_in_long_refresh": true,
        //   "progress": 0,
        //   "wallet_state": 1
        // }

        // JSON numbers come as NSNumber, need to convert properly
        if let height = status["current_wallet_height"] as? NSNumber {
            walletHeight = height.uint64Value
        }
        if let height = status["current_daemon_height"] as? NSNumber {
            daemonHeight = height.uint64Value
        }
        isDaemonConnected = status["is_daemon_connected"] as? Bool ?? false
        isInLongRefresh = status["is_in_long_refresh"] as? Bool ?? false

        if lastStoredBlockHeight < restoreHeight {
            lastStoredBlockHeight = walletHeight
        }

        let newState = evaluateState()
        logger?.debug("Sync: wallet=\(walletHeight), daemon=\(daemonHeight), longRefresh=\(isInLongRefresh) -> \(newState.description)")
        state = newState

        scheduleNextCheck()
    }

    private func scheduleNextCheck() {
        guard isRunning else { return }

        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.checkSyncState()
        }
    }

    func validateReachable() {
        if !reachabilityManager.isReachable {
            state = .idle(daemonReachable: false)
        }
    }

    func start(walletId: Int64) {
        if isRunning { return }
        isRunning = true

        self.walletId = walletId
        connectStartTime = Date()

        scheduleNextCheck()
    }

    func stop() {
        isRunning = false
        connectStartTime = nil
        walletId = nil
    }

    func walletStored() {
        lastStoredBlockHeight = walletHeight
    }
}

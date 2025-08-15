import CMonero
import Foundation
import HsToolKit

class SyncStateManager {
    static let storeBlocksCount: UInt64 = 2000

    private var timer: Timer?
    private var backgroundSyncSetupSuccess: Bool = false
    private var isCheckingState: Bool = false
    private var isRunning = false
    private var walletPointer: UnsafeMutableRawPointer?
    private var cWalletPassword: UnsafeMutablePointer<CChar>?
    private let queue = DispatchQueue(label: "monero.kit.background-sync-queue", qos: .userInitiated)
    private let logger: Logger?
    private var lastDownloadedBlockHeight: UInt64 = 0
    private var lastStateCheckedAt: TimeInterval = 0

    var state: WalletState = .init(status: .unknown, daemonHeight: nil, walletBlockHeight: nil, isSynchronized: false)

    var chunkOfBlocksSynced: Bool {
        guard let walletHeight = state.walletBlockHeight else { return false }
        return lastDownloadedBlockHeight <= walletHeight && walletHeight - lastDownloadedBlockHeight >= Self.storeBlocksCount
    }

    var stateCheckingNeeded: Bool {
        guard let walletHeight = state.walletBlockHeight, let daemonHeight = state.daemonHeight,
              daemonHeight > walletHeight
        else {
            return true
        }

        let blocksToSync = daemonHeight - walletHeight
        if blocksToSync < 100 {
            return true
        }

        let now = Date().timeIntervalSince1970
        if blocksToSync < 1000, now - lastStateCheckedAt > 10 {
            return true
        }

        if blocksToSync < 2000, now - lastStateCheckedAt > 15 {
            return true
        }

        if blocksToSync < 5000, now - lastStateCheckedAt > 20 {
            return true
        }

        if now - lastStateCheckedAt > 35 {
            return true
        }

        return false
    }

    init(logger: Logger?) {
        self.logger = logger
    }

    private func checkSyncState(onSyncStateChanged: @escaping () -> Void) {
        guard !isCheckingState, stateCheckingNeeded, let walletPtr = walletPointer else { return }
        isCheckingState = true

        let newDaemonHeight = MONERO_Wallet_daemonBlockChainHeight(walletPtr)
        let newWalletHeight = MONERO_Wallet_blockChainHeight(walletPtr)

        if newDaemonHeight <= 0 || newWalletHeight <= 0 {
            isCheckingState = false
            lastStateCheckedAt = Date().timeIntervalSince1970
            return
        }

        let newIsSynchronized = MONERO_Wallet_synchronized(walletPtr)

        let newWalletStatus = MONERO_Wallet_status(walletPtr)
        if newWalletStatus != 0 {
            let errorCStr = MONERO_Wallet_errorString(walletPtr)
            let errorStr = stringFromCString(errorCStr)
            logger?.error("Wallet is in error state (\(newWalletStatus)): \(errorStr ?? "Unknown wallet error").")
            state = .init(
                status: WalletCoreStatus(newWalletStatus, error: errorStr) ?? .unknown,
                daemonHeight: newDaemonHeight,
                walletBlockHeight: newWalletHeight,
                isSynchronized: newIsSynchronized
            )
            return
        }

        state = .init(
            status: .ok,
            daemonHeight: newDaemonHeight,
            walletBlockHeight: newWalletHeight,
            isSynchronized: newIsSynchronized
        )

        onSyncStateChanged()
        isCheckingState = false
        lastStateCheckedAt = Date().timeIntervalSince1970
    }

    func start(walletPointer: UnsafeMutableRawPointer, cWalletPassword: UnsafeMutablePointer<CChar>, onSyncStateChanged: @escaping () -> Void) {
        if isRunning { return }
        isRunning = true

        self.walletPointer = walletPointer
        self.cWalletPassword = cWalletPassword

//        if !backgroundSyncSetupSuccess {
//            backgroundSyncSetupSuccess = MONERO_Wallet_setupBackgroundSync(walletPointer, BackgroundSyncType.customPassword.rawValue, cWalletPassword, "")
//
//            if !backgroundSyncSetupSuccess {
//                let errorCStr = MONERO_Wallet_errorString(walletPointer)
//                let msg = stringFromCString(errorCStr) ?? "Setup background sync error"
//                logger?.error("Error setup Background sync: \(msg)")
//                return
//            }
//        }
//
//        let startedBackgroundSync = MONERO_Wallet_startBackgroundSync(walletPointer)
//        if !startedBackgroundSync {
//            let errorCStr = MONERO_Wallet_errorString(walletPointer)
//            let msg = stringFromCString(errorCStr) ?? "Start background sync error"
//            logger?.error("Error start Background sync: \(msg)")
//            return
//        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                self?.queue.async { [weak self] in
                    self?.checkSyncState(onSyncStateChanged: onSyncStateChanged)
                }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil

//        if let walletPtr = walletPointer {
//            let stopped = MONERO_Wallet_stopBackgroundSync(walletPtr, cWalletPassword)
//            if !stopped {
//                let errorCStr = MONERO_Wallet_errorString(walletPtr)
//                let msg = stringFromCString(errorCStr) ?? "Setup background sync error"
//                logger?.error("Error stop Background sync: \(msg)")
//                return
//            }
//        }

        walletPointer = nil
        cWalletPassword = nil
        isRunning = false
    }

    func syncCached() {
        guard let walletHeight = state.walletBlockHeight else { return }
        lastDownloadedBlockHeight = walletHeight
    }

    enum BackgroundSyncType: Int32 {
        case none = 0
        case `default` = 1
        case customPassword = 2
    }
}

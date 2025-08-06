import Foundation
import CMonero

class BackgroundSyncer {
    private var timer: Timer?
    private var backgroundSyncSetupSuccess: Bool = false
    private var isCheckingStatus: Bool = false
    private var isRunning = false
    private var walletPointer: UnsafeMutableRawPointer?
    private var cWalletPassword: UnsafeMutablePointer<CChar>?
    private let queue = DispatchQueue(label: "monero.kit.background-sync-queue", qos: .userInitiated)

    deinit {
        stop()
    }

    func start(walletPointer: UnsafeMutableRawPointer, cWalletPassword: UnsafeMutablePointer<CChar>, onStatusCheck: @escaping () -> Void) {
        if isRunning { return }
        isRunning = true

        self.walletPointer = walletPointer
        self.cWalletPassword = cWalletPassword

        if !backgroundSyncSetupSuccess {
            backgroundSyncSetupSuccess = MONERO_Wallet_setupBackgroundSync(walletPointer, BackgroundSyncType.customPassword.rawValue, cWalletPassword, "")

            if !backgroundSyncSetupSuccess {
                let errorCStr = MONERO_Wallet_errorString(walletPointer)
                let msg = stringFromCString(errorCStr) ?? "Setup background sync error"
                print("Error setup Background sync: \(msg)")
                return
            }
        }

        let startedBackgroundSync = MONERO_Wallet_startBackgroundSync(walletPointer)
        if !startedBackgroundSync {
            let errorCStr = MONERO_Wallet_errorString(walletPointer)
            let msg = stringFromCString(errorCStr) ?? "Start background sync error"
            print("Error start Background sync: \(msg)")
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    guard !isCheckingStatus else {
                        return
                    }

                    isCheckingStatus = true
                    onStatusCheck()
                    isCheckingStatus = false
                }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil

        if let walletPtr = walletPointer {
            let stopped = MONERO_Wallet_stopBackgroundSync(walletPtr, cWalletPassword)
            if !stopped {
                let errorCStr = MONERO_Wallet_errorString(walletPtr)
                let msg = stringFromCString(errorCStr) ?? "Setup background sync error"
                print("Error setup Background sync: \(msg)")
                return
            }
        }

        walletPointer = nil
        cWalletPassword = nil
        isRunning = false
    }

    enum BackgroundSyncType: Int32 {
        case none = 0
        case `default` = 1
        case customPassword = 2
    }
}

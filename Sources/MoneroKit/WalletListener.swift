import CMonero
import Foundation

class WalletListener {
    private var walletListenerPointer: UnsafeMutableRawPointer?
    private var walletPointer: UnsafeMutableRawPointer?
    private var onNewTransaction: (() -> Void)?
    private var timer: Timer?
    private var isRunning = false
    private var lockedBalanceBlockHeight: UInt64?
    private let queue = DispatchQueue(label: "monero.kit.wallet-listener-queue", qos: .userInitiated)

    private func checkListener() {
        guard let walletListenerPointer else { return }
        let hasNewTransaction = MONERO_cw_WalletListener_isNewTransactionExist(walletListenerPointer)

        if hasNewTransaction {
            onNewTransaction?()
            MONERO_cw_WalletListener_resetIsNewTransactionExist(walletListenerPointer)
        }

        if let height = lockedBalanceBlockHeight {
            let newHeight = MONERO_cw_WalletListener_height(walletListenerPointer)
            if newHeight > height, newHeight - height >= Kit.confirmationsThreshold {
                onNewTransaction?()
                lockedBalanceBlockHeight = nil
            }
        }
    }

    func start(walletPointer: UnsafeMutableRawPointer, onNewTransaction: @escaping () -> Void) {
        guard !isRunning else { return }
        isRunning = true

        self.walletPointer = walletPointer
        self.onNewTransaction = onNewTransaction

        walletListenerPointer = MONERO_cw_getWalletListener(walletPointer)
        MONERO_Wallet_startRefresh(walletPointer)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                self?.queue.async { [weak self] in
                    guard let self else { return }

                    checkListener()
                }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        onNewTransaction = nil
        walletListenerPointer = nil
        isRunning = false

        if let walletPointer {
            MONERO_Wallet_stop(walletPointer)
        }
    }

    func setLockedBalanceHeight(height: UInt64) {
        if lockedBalanceBlockHeight == nil {
            lockedBalanceBlockHeight = height
        }
    }
}

import Combine
import Foundation
import MoneroKit

class App_WalletState: ObservableObject, MoneroKitDelegate {
    @Published var balance: BalanceInfo = .init(all: 0, unlocked: 0)
    @Published var transactions: [TransactionInfo] = []
    @Published var isSynchronized: Bool = false
    @Published var lastBlockHeight: UInt64 = 0
    @Published var daemonHeight: UInt64 = 0

    // To replace walletService.walletPointer != nil logic
    @Published var isConnected: Bool = false

    func balanceDidChange(balanceInfo: BalanceInfo) {
        DispatchQueue.main.async {
            self.balance = balanceInfo
        }
    }

    func transactionsUpdated(inserted: [TransactionInfo], updated: [TransactionInfo]) {
        DispatchQueue.main.async {
            self.transactions = inserted + updated
        }
    }

    func walletStateDidChange(state: WalletState) {
        DispatchQueue.main.async {
            self.isSynchronized = state.isSynchronized
            if let height = state.walletBlockHeight {
                self.lastBlockHeight = height
            }
            if let height = state.daemonHeight {
                self.daemonHeight = height
            }
        }
    }
}

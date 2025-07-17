import Combine
import Foundation
import MoneroKit

class WalletState: ObservableObject, MoneroKitDelegate {
    @Published var balance: BalanceInfo = .init(spendable: 0, unspendable: 0)
    @Published var transactions: [TransactionInfo] = []
    @Published var isSynchronized: Bool = false
    @Published var lastBlockHeight: UInt64 = 0

    // To replace walletService.walletPointer != nil logic
    @Published var isConnected: Bool = false

    func balanceDidChange(balance: BalanceInfo) {
        DispatchQueue.main.async {
            self.balance = balance
        }
    }

    func transactionsDidChange(transactions: [TransactionInfo]) {
        DispatchQueue.main.async {
            self.transactions = transactions
        }
    }

    func syncStateDidChange(isSynchronized: Bool) {
        DispatchQueue.main.async {
            self.isSynchronized = isSynchronized
        }
    }

    func lastBlockHeightDidChange(height: UInt64) {
        DispatchQueue.main.async {
            self.lastBlockHeight = height
        }
    }
}

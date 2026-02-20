import Combine
import Foundation
import ZanoKit

@MainActor
class Zano_WalletState: ObservableObject, ZanoKitDelegate {
    @Published var balance: BalanceInfo = .init(all: 0, unlocked: 0)
    @Published var transactions: [TransactionInfo] = []
    @Published var walletState: WalletState = .notSynced(error: .notStarted)

    @Published var isConnected: Bool = false

    var isSynchronized: Bool {
        if case .synced = walletState {
            return true
        }
        return false
    }

    nonisolated func balanceDidChange(balanceInfo: BalanceInfo) {
        Task { @MainActor in
            self.balance = balanceInfo
        }
    }

    nonisolated func transactionsUpdated(inserted: [TransactionInfo], updated: [TransactionInfo]) {
        let allTransactions = inserted + updated
        Task { @MainActor in
            self.transactions = allTransactions
        }
    }

    nonisolated func walletStateDidChange(state: WalletState) {
        Task { @MainActor in
            self.walletState = state
        }
    }
}

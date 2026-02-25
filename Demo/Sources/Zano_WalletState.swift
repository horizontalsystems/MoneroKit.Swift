import Combine
import Foundation
import ZanoKit

@MainActor
class Zano_WalletState: ObservableObject, ZanoKitDelegate {
    @Published var assets: [AssetInfo] = []
    @Published var balances: [BalanceInfo] = []
    @Published var transactions: [TransactionInfo] = []
    @Published var walletState: WalletState = .notSynced(error: .notStarted)

    @Published var isConnected: Bool = false

    var isSynchronized: Bool {
        if case .synced = walletState {
            return true
        }
        return false
    }

    var nativeBalance: BalanceInfo {
        balances.first { $0.isNative } ?? BalanceInfo(assetId: ZanoAssetId, total: 0, unlocked: 0)
    }

    nonisolated func assetsDidChange(assets: [AssetInfo]) {
        Task { @MainActor in
            self.assets = assets
        }
    }

    nonisolated func balancesDidChange(balances: [BalanceInfo]) {
        Task { @MainActor in
            self.balances = balances
        }
    }

    nonisolated func transactionsDidChange(transactions: [TransactionInfo]) {
        Task { @MainActor in
            self.transactions = transactions
        }
    }

    nonisolated func walletStateDidChange(state: WalletState) {
        Task { @MainActor in
            self.walletState = state
        }
    }
}

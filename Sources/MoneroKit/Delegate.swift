import Foundation

public protocol MoneroKitDelegate: AnyObject {
    func balanceDidChange(balanceInfo: BalanceInfo)
    func transactionsUpdated(inserted: [TransactionInfo], updated: [TransactionInfo])
    func walletStatusDidChange(status: WalletStatus)
    func syncStateDidChange(state: SyncState)
}

protocol MoneroCoreDelegate: AnyObject {
    func balanceDidChange(balanceInfo: BalanceInfo)
    func transactionsDidChange(transactions: [MoneroCore.Transaction])
    func subAddresssesDidChange(subAddresses: [String])
    func walletStatusDidChange(status: WalletStatus)
    func syncStateDidChange(state: SyncState)
}

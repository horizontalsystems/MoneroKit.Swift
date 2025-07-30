import Foundation

public protocol MoneroKitDelegate: AnyObject {
    func balanceDidChange(balanceInfo: BalanceInfo)
    func transactionsUpdated(inserted: [TransactionInfo], updated: [TransactionInfo])
    func syncStateDidChange(isSynchronized: Bool)
    func lastBlockHeightDidChange(height: UInt64)
}

protocol MoneroCoreDelegate: AnyObject {
    func balanceDidChange(balanceInfo: BalanceInfo)
    func transactionsDidChange(transactions: [MoneroCore.Transaction])
    func subAddresssesDidChange(subAddresses: [String])
    func syncStateDidChange(isSynchronized: Bool)
    func lastBlockHeightDidChange(height: UInt64)
}

import Foundation

public struct BalanceInfo {
    public let spendable: UInt64
    public let unspendable: UInt64

    public init(spendable: UInt64, unspendable: UInt64) {
        self.spendable = spendable
        self.unspendable = unspendable
    }
}

public protocol MoneroKitDelegate: AnyObject {
    func balanceDidChange(balance: BalanceInfo)
    func transactionsDidChange(transactions: [TransactionInfo])
    func syncStateDidChange(isSynchronized: Bool)
    func lastBlockHeightDidChange(height: UInt64)
}

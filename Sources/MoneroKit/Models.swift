import Foundation

public struct Transfer {
    public let address: String
    public let amount: UInt64
}

public enum TransactionFilterType {
    case incoming, outgoing

    var types: [TransactionType] {
        switch self {
        case .incoming: return [.incoming, .sentToSelf]
        case .outgoing: return [.outgoing, .sentToSelf]
        }
    }
}

public struct TransactionInfo {
    public let uid: String
    public let hash: String
    public let type: TransactionType
    public let blockHeight: UInt64
    public let amount: UInt64
    public let fee: UInt64
    public let isPending: Bool
    public let isFailed: Bool
    public let timestamp: Int
    public let recipientAddress: String?

    init(transaction: Transaction) {
        uid = transaction.uid
        hash = transaction.hash
        type = transaction.type
        blockHeight = transaction.blockHeight
        amount = transaction.amount
        fee = transaction.fee
        isPending = transaction.isPending
        isFailed = transaction.isFailed
        timestamp = transaction.timestamp
        recipientAddress = transaction.recipientAddress
    }
}

public struct BalanceInfo: Equatable {
    public let all: Int
    public let unlocked: Int

    public init(all: UInt64, unlocked: UInt64) {
        self.all = Int(all)
        self.unlocked = Int(unlocked)
    }

    public static func == (lhs: BalanceInfo, rhs: BalanceInfo) -> Bool {
        lhs.all == rhs.all && lhs.unlocked == rhs.unlocked
    }
}

public enum SendPriority: Int, CaseIterable {
    case `default`, low, medium, high, last
}

public enum NetworkType: Int32, CaseIterable {
    case mainnet = 0
    case testnet = 1
    case stagenet = 2
}

public enum WalletCoreStatus {
    case unknown, ok, error(Error?), critical(Error?)

    init?(_ status: Int32, error: String?) {
        switch status {
        case 0:
            self = .ok
        case 1:
            self = .error(MoneroCoreError.walletStatusError(error))
        case 2:
            self = .critical(MoneroCoreError.walletStatusError(error))
        default:
            return nil
        }
    }
}

public struct WalletState: Equatable {
    public let status: WalletCoreStatus
    public let daemonHeight: UInt64?
    public let walletBlockHeight: UInt64?
    public let isSynchronized: Bool

    public static func == (lhs: WalletState, rhs: WalletState) -> Bool {
        switch (lhs.status, rhs.status) {
        case (.unknown, .unknown), (.ok, .ok), (.error, .error), (.critical, .critical):
            return lhs.daemonHeight == rhs.daemonHeight && lhs.walletBlockHeight == rhs.walletBlockHeight && lhs.isSynchronized == rhs.isSynchronized
        default: return false
        }
    }
}

public enum SendAmount {
    case value(Int)
    case all

    var value: UInt64 {
        switch self {
        case .all: return UInt64(0)
        case let .value(value): return UInt64(value)
        }
    }
}

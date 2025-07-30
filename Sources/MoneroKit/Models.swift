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
        self.uid = transaction.uid
        self.hash = transaction.hash
        self.type = transaction.type
        self.blockHeight = transaction.blockHeight
        self.amount = transaction.amount
        self.fee = transaction.fee
        self.isPending = transaction.isPending
        self.isFailed = transaction.isFailed
        self.timestamp = transaction.timestamp
        self.recipientAddress = transaction.recipientAddress
    }
}

public struct BalanceInfo: Equatable {
    public let all: Int
    public let unspendable: Int

    public init(all: UInt64, unspendable: UInt64) {
        self.all = Int(all)
        self.unspendable = Int(unspendable)
    }

    public static func == (lhs: BalanceInfo, rhs: BalanceInfo) -> Bool {
        lhs.all == rhs.all && lhs.unspendable == rhs.unspendable
    }
}

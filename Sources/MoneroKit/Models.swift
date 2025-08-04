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

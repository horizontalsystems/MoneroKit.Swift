import Foundation

public struct Transfer {
    public let address: String
    public let amount: UInt64
}

public struct TransactionInfo {
    public enum Direction: Int32 {
        case `in` = 0
        case out = 1
    }

    public let direction: Direction
    public let isPending: Bool
    public let isFailed: Bool
    public let amount: UInt64
    public let fee: UInt64
    public let blockHeight: UInt64
    public let confirmations: UInt64
    public let hash: String
    public let timestamp: Date
    public var transfers: [Transfer]
}

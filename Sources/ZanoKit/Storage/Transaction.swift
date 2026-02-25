import Foundation
import GRDB

// enum TransactionStatus: Int, DatabaseValueConvertible, Codable { case new, relayed, invalid }

public enum TransactionType: Int, DatabaseValueConvertible, Codable {
    case incoming = 1
    case outgoing = 2
    case sentToSelf = 3
}

class Transaction: Record {
    var uid: String
    var hash: String
    var assetId: String
    var type: TransactionType
    var blockHeight: UInt64
    var amount: Int64
    var fee: UInt64
    var isPending: Bool
    var isFailed: Bool
    var timestamp: Int
    var note: String?
    var recipientAddress: String?

    init(hash: String, assetId: String, type: TransactionType, blockHeight: UInt64, amount: Int64, fee: UInt64, isPending: Bool, isFailed: Bool, timestamp: Int, note: String?, recipientAddress: String?) {
        // UID is derived from hash + assetId for consistency
        uid = "\(hash)_\(assetId)"
        self.hash = hash
        self.assetId = assetId
        self.type = type
        self.blockHeight = blockHeight
        self.amount = amount
        self.fee = fee
        self.isPending = isPending
        self.isFailed = isFailed
        self.timestamp = timestamp
        self.note = note
        self.recipientAddress = recipientAddress

        super.init()
    }

    override open class var databaseTableName: String {
        "transactions"
    }

    enum Columns: String, ColumnExpression, CaseIterable {
        case uid
        case hash
        case assetId
        case type
        case blockHeight
        case amount
        case fee
        case isPending
        case isFailed
        case timestamp
        case note
        case recipientAddress
    }

    required init(row: Row) throws {
        uid = row[Columns.uid]
        hash = row[Columns.hash]
        assetId = row[Columns.assetId]
        type = row[Columns.type]
        blockHeight = row[Columns.blockHeight]
        amount = row[Columns.amount]
        fee = row[Columns.fee]
        isPending = row[Columns.isPending]
        isFailed = row[Columns.isFailed]
        timestamp = row[Columns.timestamp]
        note = row[Columns.note]
        recipientAddress = row[Columns.recipientAddress]

        try super.init(row: row)
    }

    override open func encode(to container: inout PersistenceContainer) throws {
        container[Columns.uid] = uid
        container[Columns.hash] = hash
        container[Columns.assetId] = assetId
        container[Columns.type] = type
        container[Columns.blockHeight] = blockHeight
        container[Columns.amount] = amount
        container[Columns.fee] = fee
        container[Columns.isPending] = isPending
        container[Columns.isFailed] = isFailed
        container[Columns.timestamp] = timestamp
        container[Columns.note] = note
        container[Columns.recipientAddress] = recipientAddress
    }
}

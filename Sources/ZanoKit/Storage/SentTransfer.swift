import Foundation
import GRDB

class SentTransfer: Record {
    var txHash: String
    var assetId: String
    var amount: Int64
    var address: String

    init(txHash: String, assetId: String, amount: Int64, address: String) {
        self.txHash = txHash
        self.assetId = assetId
        self.amount = amount
        self.address = address
        super.init()
    }

    override open class var databaseTableName: String {
        "sent_transfers"
    }

    enum Columns: String, ColumnExpression, CaseIterable {
        case txHash
        case assetId
        case amount
        case address
    }

    required init(row: Row) throws {
        txHash = row[Columns.txHash]
        assetId = row[Columns.assetId]
        amount = row[Columns.amount]
        address = row[Columns.address]
        try super.init(row: row)
    }

    override open func encode(to container: inout PersistenceContainer) throws {
        container[Columns.txHash] = txHash
        container[Columns.assetId] = assetId
        container[Columns.amount] = amount
        container[Columns.address] = address
    }
}

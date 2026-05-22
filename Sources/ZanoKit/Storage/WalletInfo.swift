import Foundation
import GRDB

class WalletInfo: Record {
    var id: String = "single-row-id"
    // Stored as text to safely handle UInt64 values > Int64.max
    var creationTimestampText: String

    init(creationTimestamp: UInt64) {
        creationTimestampText = String(creationTimestamp)
        super.init()
    }

    override open class var databaseTableName: String {
        "wallet_info"
    }

    enum Columns: String, ColumnExpression, CaseIterable {
        case id
        case creationTimestampText
    }

    required init(row: Row) throws {
        id = row[Columns.id]
        creationTimestampText = row[Columns.creationTimestampText]
        try super.init(row: row)
    }

    override open func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.creationTimestampText] = creationTimestampText
    }

    var creationTimestamp: UInt64 {
        UInt64(creationTimestampText) ?? 0
    }
}

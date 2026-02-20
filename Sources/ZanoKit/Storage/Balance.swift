import Foundation
import GRDB

class Balance: Record {
    var assetId: String
    var total: Int64
    var unlocked: Int64
    var awaitingIn: Int64
    var awaitingOut: Int64

    init(assetId: String, total: Int64, unlocked: Int64, awaitingIn: Int64 = 0, awaitingOut: Int64 = 0) {
        self.assetId = assetId
        self.total = total
        self.unlocked = unlocked
        self.awaitingIn = awaitingIn
        self.awaitingOut = awaitingOut

        super.init()
    }

    override open class var databaseTableName: String {
        "balances"
    }

    enum Columns: String, ColumnExpression, CaseIterable {
        case assetId
        case total
        case unlocked
        case awaitingIn
        case awaitingOut
    }

    required init(row: Row) throws {
        assetId = row[Columns.assetId]
        total = row[Columns.total]
        unlocked = row[Columns.unlocked]
        awaitingIn = row[Columns.awaitingIn]
        awaitingOut = row[Columns.awaitingOut]

        try super.init(row: row)
    }

    override open func encode(to container: inout PersistenceContainer) throws {
        container[Columns.assetId] = assetId
        container[Columns.total] = total
        container[Columns.unlocked] = unlocked
        container[Columns.awaitingIn] = awaitingIn
        container[Columns.awaitingOut] = awaitingOut
    }
}

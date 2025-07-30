import Foundation
import GRDB

class SubAddress: Record {
    var account: Int
    var address: String

    init(account: Int, address: String) {
        self.account = account
        self.address = address

        super.init()
    }

    override open class var databaseTableName: String {
        "SubAddresss"
    }

    enum Columns: String, ColumnExpression, CaseIterable {
        case account
        case address
    }

    required init(row: Row) throws {
        account = row[Columns.account]
        address = row[Columns.address]

        try super.init(row: row)
    }

    override open func encode(to container: inout PersistenceContainer) throws {
        container[Columns.account] = account
        container[Columns.address] = address
    }
}

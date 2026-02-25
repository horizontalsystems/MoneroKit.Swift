import Foundation
import GRDB

class BlockHeights: Record {
    var id: String = "single-row-id"
    var daemonHeight: UInt64
    var walletHeight: UInt64

    init(daemonHeight: UInt64, walletHeight: UInt64) {
        self.daemonHeight = daemonHeight
        self.walletHeight = walletHeight

        super.init()
    }

    override open class var databaseTableName: String {
        "BlockHeights"
    }

    enum Columns: String, ColumnExpression, CaseIterable {
        case id
        case daemonHeight
        case walletHeight
    }

    required init(row: Row) throws {
        id = row[Columns.id]
        daemonHeight = row[Columns.daemonHeight]
        walletHeight = row[Columns.walletHeight]

        try super.init(row: row)
    }

    override open func encode(to container: inout PersistenceContainer) throws {
        container[Columns.daemonHeight] = daemonHeight
        container[Columns.walletHeight] = walletHeight
        container[Columns.id] = id
    }
}

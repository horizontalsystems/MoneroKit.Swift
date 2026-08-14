import Foundation
import GRDB

class Account: Record {
    var index: Int
    var label: String?
    var all: Int64
    var unlocked: Int64

    init(index: Int, label: String?, all: UInt64, unlocked: UInt64) {
        self.index = index
        self.label = label
        self.all = Int64(clamping: all)
        self.unlocked = Int64(clamping: unlocked)

        super.init()
    }

    override open class var databaseTableName: String {
        "accounts"
    }

    enum Columns: String, ColumnExpression, CaseIterable {
        case index
        case label
        case all
        case unlocked
    }

    required init(row: Row) throws {
        index = row[Columns.index]
        label = row[Columns.label]
        all = row[Columns.all] as Int64
        unlocked = row[Columns.unlocked] as Int64

        try super.init(row: row)
    }

    override open func encode(to container: inout PersistenceContainer) throws {
        container[Columns.index] = index
        container[Columns.label] = label
        container[Columns.all] = all
        container[Columns.unlocked] = unlocked
    }
}

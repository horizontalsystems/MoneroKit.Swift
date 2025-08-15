import Foundation
import GRDB

class GrdbStorage {
    var dbPool: DatabasePool

    init(databaseFilePath: String) {
        dbPool = try! DatabasePool(path: databaseFilePath)

        try? migrator.migrate(dbPool)
    }

    var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("createTransactions") { db in
            try db.create(table: Transaction.databaseTableName) { t in
                t.column(Transaction.Columns.uid.name, .text).notNull()
                t.column(Transaction.Columns.hash.name, .text).notNull()
                t.column(Transaction.Columns.type.name, .integer).notNull()
                t.column(Transaction.Columns.blockHeight.name, .integer).notNull()
                t.column(Transaction.Columns.amount.name, .integer).notNull()
                t.column(Transaction.Columns.fee.name, .integer).notNull()
                t.column(Transaction.Columns.isPending.name, .boolean).notNull()
                t.column(Transaction.Columns.isFailed.name, .boolean).notNull()
                t.column(Transaction.Columns.timestamp.name, .integer).notNull()
                t.column(Transaction.Columns.recipientAddress.name, .text)

                t.primaryKey([Transaction.Columns.hash.name], onConflict: .replace)
            }
        }

        migrator.registerMigration("createSubAddresses") { db in
            try db.create(table: SubAddress.databaseTableName) { t in
                t.column(SubAddress.Columns.account.name, .text).notNull()
                t.column(SubAddress.Columns.address.name, .text).notNull()

                t.primaryKey([SubAddress.Columns.address.name], onConflict: .replace)
            }
        }

        migrator.registerMigration("createBlockHeifhts") { db in
            try db.create(table: BlockHeights.databaseTableName) { t in
                t.column(BlockHeights.Columns.id.name, .text).notNull()
                t.column(BlockHeights.Columns.daemonHeight.name, .text).notNull()
                t.column(BlockHeights.Columns.walletHeight.name, .text).notNull()

                t.primaryKey([BlockHeights.Columns.id.name], onConflict: .replace)
            }
        }

        return migrator
    }

    func transaction(byUid: String) -> Transaction? {
        try! dbPool.read { db in
            try Transaction.filter(Transaction.Columns.uid == byUid).fetchOne(db)
        }
    }

    func transactions(fromTimestamp: Int?, type: TransactionFilterType?, limit: Int?) -> [Transaction] {
        try! dbPool.read { db in
            var query = Transaction.filter(Transaction.Columns.timestamp < (fromTimestamp ?? Int.max))

            if let type {
                query = query.filter(type.types.contains(Transaction.Columns.type))
            }

            return try query.limit(limit ?? 100).fetchAll(db)
        }
    }

    func update(transactions: [Transaction]) {
        try! dbPool.write { db in
            try Transaction.deleteAll(db)

            for transaction in transactions {
                try transaction.insert(db)
            }
        }
    }

    func update(subAddresses: [String], account: Int) {
        try! dbPool.write { db in
            try SubAddress.filter(SubAddress.Columns.account == account).deleteAll(db)
            for address in subAddresses {
                try SubAddress(account: account, address: address).insert(db)
            }
        }
    }

    func addressExists(_ address: String) -> Bool {
        try! dbPool.read { db in
            try SubAddress.filter(SubAddress.Columns.address == address).fetchOne(db) != nil
        }
    }

    func update(blockHeights: BlockHeights) {
        try! dbPool.write { db in
            try BlockHeights.deleteAll(db)
            try blockHeights.insert(db)
        }
    }

    func getBlockHeights() -> BlockHeights? {
        try! dbPool.read { db in
            try BlockHeights.fetchOne(db)
        }
    }
}

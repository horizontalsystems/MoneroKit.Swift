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

        migrator.registerMigration("createAssets") { db in
            try db.create(table: Asset.databaseTableName) { t in
                t.column(Asset.Columns.assetId.name, .text).notNull()
                t.column(Asset.Columns.ticker.name, .text).notNull()
                t.column(Asset.Columns.fullName.name, .text).notNull()
                t.column(Asset.Columns.decimalPoint.name, .integer).notNull()
                // Store as TEXT to handle UInt64 values > Int64.max
                t.column(Asset.Columns.totalMaxSupply.name, .text).notNull()
                t.column(Asset.Columns.currentSupply.name, .text).notNull()
                t.column(Asset.Columns.metaInfo.name, .text)

                t.primaryKey([Asset.Columns.assetId.name], onConflict: .replace)
            }
        }

        migrator.registerMigration("createBalances") { db in
            try db.create(table: Balance.databaseTableName) { t in
                t.column(Balance.Columns.assetId.name, .text).notNull()
                t.column(Balance.Columns.total.name, .integer).notNull()
                t.column(Balance.Columns.unlocked.name, .integer).notNull()
                t.column(Balance.Columns.awaitingIn.name, .integer).notNull()
                t.column(Balance.Columns.awaitingOut.name, .integer).notNull()

                t.primaryKey([Balance.Columns.assetId.name], onConflict: .replace)
            }
        }

        migrator.registerMigration("createTransactions") { db in
            try db.create(table: Transaction.databaseTableName) { t in
                t.column(Transaction.Columns.uid.name, .text).notNull()
                t.column(Transaction.Columns.hash.name, .text).notNull()
                t.column(Transaction.Columns.assetId.name, .text).notNull()
                t.column(Transaction.Columns.type.name, .integer).notNull()
                t.column(Transaction.Columns.blockHeight.name, .integer).notNull()
                t.column(Transaction.Columns.amount.name, .integer).notNull()
                t.column(Transaction.Columns.fee.name, .integer).notNull()
                t.column(Transaction.Columns.isPending.name, .boolean).notNull()
                t.column(Transaction.Columns.isFailed.name, .boolean).notNull()
                t.column(Transaction.Columns.timestamp.name, .integer).notNull()
                t.column(Transaction.Columns.note.name, .text)
                t.column(Transaction.Columns.recipientAddress.name, .text)

                // Primary key is hash + assetId since one tx can transfer multiple assets
                t.primaryKey([Transaction.Columns.hash.name, Transaction.Columns.assetId.name], onConflict: .replace)
            }
        }

        migrator.registerMigration("createBlockHeights") { db in
            try db.create(table: BlockHeights.databaseTableName) { t in
                t.column(BlockHeights.Columns.id.name, .text).notNull()
                t.column(BlockHeights.Columns.daemonHeight.name, .integer).notNull()
                t.column(BlockHeights.Columns.walletHeight.name, .integer).notNull()

                t.primaryKey([BlockHeights.Columns.id.name], onConflict: .replace)
            }
        }

        migrator.registerMigration("createSentTransfers") { db in
            try db.create(table: SentTransfer.databaseTableName) { t in
                t.column(SentTransfer.Columns.txHash.name, .text).notNull()
                t.column(SentTransfer.Columns.assetId.name, .text).notNull()
                t.column(SentTransfer.Columns.amount.name, .integer).notNull()
                t.column(SentTransfer.Columns.address.name, .text).notNull()

                t.primaryKey([SentTransfer.Columns.txHash.name], onConflict: .replace)
            }
        }

        return migrator
    }

    // MARK: - Assets

    func update(assets: [Asset]) {
        try! dbPool.write { db in
            try Asset.deleteAll(db)
            for asset in assets {
                try asset.insert(db)
            }
        }
    }

    func getAsset(byId assetId: String) -> Asset? {
        try! dbPool.read { db in
            try Asset.filter(Asset.Columns.assetId == assetId).fetchOne(db)
        }
    }

    func getAllAssets() -> [Asset] {
        try! dbPool.read { db in
            try Asset.fetchAll(db)
        }
    }

    // MARK: - Balances

    func update(balances: [Balance]) {
        try! dbPool.write { db in
            try Balance.deleteAll(db)
            for balance in balances {
                try balance.insert(db)
            }
        }
    }

    func getBalance(forAssetId assetId: String) -> Balance? {
        try! dbPool.read { db in
            try Balance.filter(Balance.Columns.assetId == assetId).fetchOne(db)
        }
    }

    func getAllBalances() -> [Balance] {
        try! dbPool.read { db in
            try Balance.fetchAll(db)
        }
    }

    // MARK: - Transactions

    func transaction(byHash hash: String) -> Transaction? {
        try! dbPool.read { db in
            try Transaction.filter(Transaction.Columns.hash == hash).fetchOne(db)
        }
    }

    func transactions(assetId: String? = nil, fromTimestamp: Int? = nil, descending: Bool = true, type: TransactionFilterType? = nil, limit: Int? = nil) -> [Transaction] {
        try! dbPool.read { db in
            var query = Transaction.order(descending ? Transaction.Columns.timestamp.desc : Transaction.Columns.timestamp.asc)

            if let assetId {
                query = query.filter(Transaction.Columns.assetId == assetId)
            }

            if let fromTimestamp {
                query = query.filter(descending ? Transaction.Columns.timestamp < fromTimestamp : Transaction.Columns.timestamp > fromTimestamp)
            }

            if let type {
                query = query.filter(type.types.contains(Transaction.Columns.type))
            }

            if let limit {
                query = query.limit(limit)
            }

            return try query.fetchAll(db)
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

    // MARK: - Sent Transfers

    func saveSentTransfer(_ sentTransfer: SentTransfer) {
        try! dbPool.write { db in
            try sentTransfer.save(db)
        }
    }

    func sentTransfer(byTxHash txHash: String) -> SentTransfer? {
        try! dbPool.read { db in
            try SentTransfer.filter(SentTransfer.Columns.txHash == txHash).fetchOne(db)
        }
    }

    func allSentTransfers() -> [SentTransfer] {
        try! dbPool.read { db in
            try SentTransfer.fetchAll(db)
        }
    }

    // MARK: - Block Heights

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

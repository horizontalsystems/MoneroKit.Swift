import Foundation
import GRDB

class Asset: Record {
    var assetId: String
    var ticker: String
    var fullName: String
    var decimalPoint: Int
    var totalMaxSupply: UInt64
    var currentSupply: UInt64
    var metaInfo: String?

    init(assetId: String, ticker: String, fullName: String, decimalPoint: Int, totalMaxSupply: UInt64, currentSupply: UInt64, metaInfo: String?) {
        self.assetId = assetId
        self.ticker = ticker
        self.fullName = fullName
        self.decimalPoint = decimalPoint
        self.totalMaxSupply = totalMaxSupply
        self.currentSupply = currentSupply
        self.metaInfo = metaInfo

        super.init()
    }

    override open class var databaseTableName: String {
        "assets"
    }

    enum Columns: String, ColumnExpression, CaseIterable {
        case assetId
        case ticker
        case fullName
        case decimalPoint
        case totalMaxSupply
        case currentSupply
        case metaInfo
    }

    required init(row: Row) throws {
        assetId = row[Columns.assetId]
        ticker = row[Columns.ticker]
        fullName = row[Columns.fullName]
        decimalPoint = row[Columns.decimalPoint]
        // Stored as TEXT to handle values > Int64.max
        let totalMaxSupplyStr: String = row[Columns.totalMaxSupply]
        totalMaxSupply = UInt64(totalMaxSupplyStr) ?? 0
        let currentSupplyStr: String = row[Columns.currentSupply]
        currentSupply = UInt64(currentSupplyStr) ?? 0
        metaInfo = row[Columns.metaInfo]

        try super.init(row: row)
    }

    override open func encode(to container: inout PersistenceContainer) throws {
        container[Columns.assetId] = assetId
        container[Columns.ticker] = ticker
        container[Columns.fullName] = fullName
        container[Columns.decimalPoint] = decimalPoint
        // Store as TEXT to handle values > Int64.max
        container[Columns.totalMaxSupply] = String(totalMaxSupply)
        container[Columns.currentSupply] = String(currentSupply)
        container[Columns.metaInfo] = metaInfo
    }
}

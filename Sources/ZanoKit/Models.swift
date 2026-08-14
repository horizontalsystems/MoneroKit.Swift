import Foundation

// MARK: - Constants

/// Native ZANO asset ID
public let ZanoAssetId = "d6329b5b1f7c0805b5c345f4957554002a2f557845f64d7645dae0e051a6498a"

/// Mainnet asset ids of https://api.zano.org/assets_whitelist.json, pinned into the wallet's
/// local whitelist on start so these assets stay visible even when the runtime global-whitelist
/// fetch fails (endpoint down, DNS blocked, offline).
public let GlobalWhitelistAssetIds = [
    "93da681503353509367e241cda3234299dedbbad9ec851de31e900490807bf0c", // ETHX Wrapped Ethereum
    "040a180aca4194a158c17945dd115db42086f6f074c1f77838621a4927fffa91", // BTCX Wrapped Bitcoin
    "86143388bd056a8f0bab669f78f14873fac8e2dd8d57898cdb725a2d5e2e4f8f", // FUSD Freedom Dollar
    "3de9ad7243afa49e0ade6839e97a9f10a527c4958ece2fc9cb1b87a44032167d", // BCHX Wrapped Bitcoin Cash
    "bfa6609a94e39f418d9adb000f89edc7bd180fd120f1cd272201220e3070fb4f", // TONX Wrapped TON
    "65b3bc549c8bc2c773781d5436f25f7af84644e61baaabd675d9867b007d17b4", // SOLX Wrapped Solana
    "6ca3fa07f1b6a75b6e195d2918c32228765968b54ea691c75958affa1c4073fb", // BNBX Wrapped BNB
    "24819c4b65786c3ac424e05d9ef4ab212de6222cc73bc5c4b012df5a3107eea4", // DAIX Wrapped Dai
]

// MARK: - Asset

public struct AssetInfo: Equatable {
    public let assetId: String
    public let ticker: String
    public let fullName: String
    public let decimalPoint: Int
    public let totalMaxSupply: UInt64
    public let currentSupply: UInt64
    public let metaInfo: String?

    public var isNative: Bool {
        assetId == ZanoAssetId
    }

    init(asset: Asset) {
        assetId = asset.assetId
        ticker = asset.ticker
        fullName = asset.fullName
        decimalPoint = asset.decimalPoint
        totalMaxSupply = asset.totalMaxSupply
        currentSupply = asset.currentSupply
        metaInfo = asset.metaInfo
    }

    public init(assetId: String, ticker: String, fullName: String, decimalPoint: Int, totalMaxSupply: UInt64, currentSupply: UInt64, metaInfo: String?) {
        self.assetId = assetId
        self.ticker = ticker
        self.fullName = fullName
        self.decimalPoint = decimalPoint
        self.totalMaxSupply = totalMaxSupply
        self.currentSupply = currentSupply
        self.metaInfo = metaInfo
    }
}

// MARK: - Balance

public struct BalanceInfo: Equatable {
    public let assetId: String
    public let total: Int64
    public let unlocked: Int64
    public let awaitingIn: Int64
    public let awaitingOut: Int64

    public var isNative: Bool {
        assetId == ZanoAssetId
    }

    init(balance: Balance) {
        assetId = balance.assetId
        total = balance.total
        unlocked = balance.unlocked
        awaitingIn = balance.awaitingIn
        awaitingOut = balance.awaitingOut
    }

    public init(assetId: String, total: Int64, unlocked: Int64, awaitingIn: Int64 = 0, awaitingOut: Int64 = 0) {
        self.assetId = assetId
        self.total = total
        self.unlocked = unlocked
        self.awaitingIn = awaitingIn
        self.awaitingOut = awaitingOut
    }
}

// MARK: - Transaction

public enum TransactionFilterType {
    case incoming, outgoing

    var types: [TransactionType] {
        switch self {
        case .incoming: return [.incoming, .sentToSelf]
        case .outgoing: return [.outgoing, .sentToSelf]
        }
    }
}

public struct TransactionInfo {
    public let uid: String
    public let hash: String
    public let assetId: String
    public let type: TransactionType
    public let blockHeight: UInt64
    public let amount: Int64
    public let fee: UInt64
    public let isPending: Bool
    public let isFailed: Bool
    public let timestamp: Int
    public let memo: String?
    public let recipientAddress: String?

    public var isNative: Bool {
        assetId == ZanoAssetId
    }

    init(transaction: Transaction) {
        uid = transaction.uid
        hash = transaction.hash
        assetId = transaction.assetId
        type = transaction.type
        blockHeight = transaction.blockHeight
        amount = transaction.amount
        fee = transaction.fee
        isPending = transaction.isPending
        isFailed = transaction.isFailed
        timestamp = transaction.timestamp
        memo = transaction.note
        recipientAddress = transaction.recipientAddress
    }
}

// MARK: - Send

public enum SendPriority: Int, CaseIterable {
    case `default`, low, medium, high
}

public enum SendAmount {
    case value(Int)
    case all

    var value: UInt64 {
        switch self {
        case .all: return UInt64(0)
        case let .value(value): return UInt64(value)
        }
    }
}

// MARK: - Network

public enum NetworkType: Int32, CaseIterable {
    case mainnet = 0
    case testnet = 1
}

// MARK: - Wallet State

public enum WalletState: Equatable {
    case synced
    case connecting(waiting: Bool)
    case syncing(progress: Int, remainingBlocksCount: Int)
    case notSynced(error: WalletStateError)
    case idle(daemonReachable: Bool)

    public static func == (lhs: WalletState, rhs: WalletState) -> Bool {
        switch (lhs, rhs) {
        case (.synced, .synced): return true
        case let (.connecting(lhsWaiting), .connecting(rhsWaiting)): return lhsWaiting == rhsWaiting
        case let (.syncing(lhsProgress, lhsRemaining), .syncing(rhsProgress, rhsRemaining)): return lhsProgress == rhsProgress && lhsRemaining == rhsRemaining
        case let (.notSynced(lhsError), .notSynced(rhsError)): return lhsError == rhsError
        case let (.idle(lhsDaemonReachable), .idle(rhsDaemonReachable)): return lhsDaemonReachable == rhsDaemonReachable
        default: return false
        }
    }

    var description: String {
        switch self {
        case .synced: return "Synced"
        case let .connecting(waiting): return waiting ? "Connecting (waiting)" : "Connecting"
        case let .syncing(progress, remainingBlocksCount): return "Syncing (\(progress)%, remaining blocks: \(remainingBlocksCount))"
        case let .notSynced(error: error): return "Not synced (\(error.description))"
        case let .idle(daemonReachable: daemonReachable): return "Idle daemon (\(daemonReachable ? "reachable" : "unreachable"))"
        }
    }
}

public enum WalletStateError: Error, Equatable {
    case notStarted
    case startError(String?)
    case statusError(String?)

    var description: String {
        switch self {
        case .notStarted: return "Not started"
        case let .startError(message): return "Start error: \(message ?? "No message")"
        case let .statusError(message): return "Status error: \(message ?? "No message")"
        }
    }
}

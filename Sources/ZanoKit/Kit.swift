import CZano // for ZANO_PlainWallet_getVersion() in coreVersion
import Foundation
import HsToolKit

public class Kit {
    public static let confirmationsThreshold: UInt64 = 10

    private let zanoCore: ZanoCore
    private let storage: GrdbStorage
    private let kitId = UUID().uuidString
    private let lifecycleQueue = DispatchQueue(label: "io.horizontalsystems.zano_kit.kit_lifecycle_queue", qos: .utility)
    private let walletDirectoryName: String
    private var started = false

    public weak var delegate: ZanoKitDelegate?

    public init(wallet: ZanoWallet, walletId: String, daemonAddress: String, networkType: NetworkType = .mainnet, reachabilityManager: ReachabilityManager, logger: Logger?, zanoCoreLogLevel: Int32? = nil) throws {
        let baseDirectoryName = "ZanoKit/\(walletId)/network_\(networkType.rawValue)"
        let baseDirectoryUrl = try FileHandler.directoryURL(for: baseDirectoryName)

        let databasePath = baseDirectoryUrl.appendingPathComponent("storage").path
        storage = GrdbStorage(databaseFilePath: databasePath)

        walletDirectoryName = "\(baseDirectoryName)/zano_core"
        let walletDirectoryUrl = try FileHandler.directoryURL(for: walletDirectoryName)
        let walletPath = walletDirectoryUrl.appendingPathComponent("wallet").path
        let workingDir = walletDirectoryUrl.path

        let logger = logger ?? Logger(minLogLevel: .verbose)

        zanoCore = ZanoCore(
            wallet: wallet,
            walletPath: walletPath,
            workingDir: workingDir,
            walletPassword: walletId,
            daemonAddress: daemonAddress,
            networkType: networkType,
            reachabilityManager: reachabilityManager,
            logger: logger,
            zanoCoreLogLevel: zanoCoreLogLevel,
            storedCreationTimestamp: storage.getCreationTimestamp(),
            onFirstRestore: { [weak storage] timestamp in
                storage?.saveCreationTimestamp(timestamp)
            }
        )

        // Restore in-memory sent transfer map from persisted GRDB records
        zanoCore.sentTransfersMap = Dictionary(uniqueKeysWithValues: storage.allSentTransfers().map {
            ($0.txHash, ZanoCore.SendResult(txHash: $0.txHash, assetId: $0.assetId, amount: UInt64(bitPattern: $0.amount), address: $0.address))
        })

        zanoCore.delegate = self
    }

    deinit {
        let zanoCore = zanoCore
        let kitId = kitId
        let started = started

        lifecycleQueue.async {
            guard started else { return }

            zanoCore.stop()
            KitManager.shared.removeRunning(kitId: kitId)
        }
    }

    // MARK: - Public Properties

    public var lastBlockInfo: UInt64 {
        if let heights = zanoCore.blockHeights {
            return heights.0
        }
        return storage.getBlockHeights()?.walletHeight ?? 0
    }

    public var daemonBlockHeight: UInt64 {
        if let heights = zanoCore.blockHeights {
            return heights.1
        }
        return storage.getBlockHeights()?.daemonHeight ?? 0
    }

    public var walletState: WalletState {
        zanoCore.state
    }

    public var receiveAddress: String {
        zanoCore.walletAddress
    }

    public var statusInfo: [(String, Any)] {
        var info: [(String, Any)] = []
        info.append(("State", walletState.description))
        if let heights = zanoCore.blockHeights {
            info.append(("Wallet Height", heights.0))
            info.append(("Daemon Height", heights.1))
        }
        info.append(("Node", zanoCore.daemonAddress))
        return info
    }

    // MARK: - Assets

    public var assets: [AssetInfo] {
        storage.getAllAssets().map { AssetInfo(asset: $0) }
    }

    public func asset(byId assetId: String) -> AssetInfo? {
        storage.getAsset(byId: assetId).map { AssetInfo(asset: $0) }
    }

    // MARK: - Balances

    public var balances: [BalanceInfo] {
        storage.getAllBalances().map { BalanceInfo(balance: $0) }
    }

    public func balance(forAssetId assetId: String) -> BalanceInfo? {
        storage.getBalance(forAssetId: assetId).map { BalanceInfo(balance: $0) }
    }

    public var nativeBalance: BalanceInfo {
        balance(forAssetId: ZanoAssetId) ?? BalanceInfo(assetId: ZanoAssetId, total: 0, unlocked: 0)
    }

    // MARK: - Transactions

    public func transactions(assetId: String? = nil, fromHash: String? = nil, descending: Bool = true, type: TransactionFilterType? = nil, limit: Int? = nil) -> [TransactionInfo] {
        var fromTimestamp: Int?
        if let fromHash {
            fromTimestamp = storage.transaction(byHash: fromHash)?.timestamp
        }

        return storage.transactions(assetId: assetId, fromTimestamp: fromTimestamp, descending: descending, type: type, limit: limit)
            .map { TransactionInfo(transaction: $0) }
    }

    // MARK: - Lifecycle Methods

    private func _start() {
        guard !started else { return }
        started = true

        var kitState = KitManager.shared.checkAndGetInitialState(kitId: kitId)

        while kitState == .waiting {
            zanoCore.setConnectingState(waiting: true)
            Thread.sleep(forTimeInterval: 1.0)
            kitState = KitManager.shared.checkAndGetState(kitId: kitId)
        }

        if kitState == .running {
            zanoCore.setConnectingState(waiting: false)
            do {
                try zanoCore.start()
            } catch {
                if let coreError = error as? ZanoCoreError, case .restoreHeightDontMatch = coreError {
                    do {
                        try FileHandler.remove(for: walletDirectoryName)
                        _ = try FileHandler.directoryURL(for: walletDirectoryName)
                        storage.clearStorage()
                        zanoCore.sentTransfersMap = [:]
                        try zanoCore.start()
                    } catch {
                        print(error)
                    }
                }
            }
        }
    }

    private func _stop() {
        guard started else { return }
        started = false

        zanoCore.stop()
        KitManager.shared.removeRunning(kitId: kitId)
    }

    private func _restart() {
        _stop()
        _start()
    }

    public func start() {
        zanoCore.setConnectingState(waiting: false)
        lifecycleQueue.async { [weak self] in
            self?._start()
        }
    }

    public func stop() {
        lifecycleQueue.async { [weak self] in
            self?._stop()
        }
    }

    public func refresh() {
        zanoCore.refresh()
    }

    public func restart() {
        lifecycleQueue.async { [weak self] in
            self?._restart()
        }
    }

    // MARK: - Sending

    @discardableResult
    public func send(to address: String, assetId: String = ZanoAssetId, amount: SendAmount, priority: SendPriority = .default, memo: String?) throws -> String {
        let fee = estimateFee(priority: priority)
        let amountValue: UInt64

        switch amount {
        case let .value(value):
            amountValue = UInt64(value)
        case .all:
            // For send all, use unlocked balance
            guard let balance = zanoCore.getBalance(forAssetId: assetId) else {
                throw ZanoCoreError.insufficientFunds("0")
            }
            if assetId == ZanoAssetId {
                // For native ZANO, subtract fee from balance (fee is paid in ZANO)
                if balance.unlocked <= Int64(fee) {
                    throw ZanoCoreError.insufficientFunds("0")
                }
                amountValue = UInt64(balance.unlocked) - fee
            } else {
                // For other assets, send full balance (fee is paid separately in ZANO)
                if balance.unlocked <= 0 {
                    throw ZanoCoreError.insufficientFunds("0")
                }
                amountValue = UInt64(balance.unlocked)
            }
        }

        let result = try zanoCore.send(to: address, assetId: assetId, amount: amountValue, fee: fee, comment: memo)
        storage.saveSentTransfer(SentTransfer(txHash: result.txHash, assetId: result.assetId, amount: Int64(bitPattern: result.amount), address: result.address))
        return result.txHash
    }

    public func estimateFee(priority: SendPriority = .default) -> UInt64 {
        ZanoWalletAPI.estimateFee(priority: UInt64(priority.rawValue))
    }
}

// MARK: - ZanoCoreDelegate

extension Kit: ZanoCoreDelegate {
    func assetsDidChange(assets: [ZanoCore.Asset]) {
        let assetRecords = assets.map { asset in
            Asset(
                assetId: asset.assetId,
                ticker: asset.ticker,
                fullName: asset.fullName,
                decimalPoint: asset.decimalPoint,
                totalMaxSupply: asset.totalMaxSupply,
                currentSupply: asset.currentSupply,
                metaInfo: asset.metaInfo
            )
        }
        storage.update(assets: assetRecords)

        let assetInfos = assetRecords.map { AssetInfo(asset: $0) }
        delegate?.assetsDidChange(assets: assetInfos)
    }

    func balancesDidChange(balances: [ZanoCore.AssetBalance]) {
        let balanceRecords = balances.map { balance in
            Balance(
                assetId: balance.assetId,
                total: balance.total,
                unlocked: balance.unlocked,
                awaitingIn: balance.awaitingIn,
                awaitingOut: balance.awaitingOut
            )
        }
        storage.update(balances: balanceRecords)

        let balanceInfos = balanceRecords.map { BalanceInfo(balance: $0) }
        delegate?.balancesDidChange(balances: balanceInfos)
    }

    func transactionsDidChange(transactions: [ZanoCore.Transaction]) {
        let transactionRecords = transactions.map { tx in
            Transaction(
                hash: tx.hash,
                assetId: tx.assetId,
                type: tx.type,
                blockHeight: tx.blockHeight,
                amount: tx.amount,
                fee: tx.fee,
                isPending: tx.isPending,
                isFailed: tx.isFailed,
                timestamp: tx.timestamp,
                note: tx.note,
                recipientAddress: tx.recipientAddress
            )
        }

        storage.update(transactions: transactionRecords)

        let transactionInfos = transactionRecords.map { TransactionInfo(transaction: $0) }
        delegate?.transactionsDidChange(transactions: transactionInfos)
    }

    func walletStateDidChange(state: WalletState) {
        delegate?.walletStateDidChange(state: state)
    }
}

// MARK: - Static Methods

public extension Kit {
    static func removeAll(except excludedFiles: [String]) throws {
        try FileHandler.removeAll(except: excludedFiles)
    }

    static func isValid(address: String, networkType _: NetworkType) -> Bool {
        ZanoCore.isValid(address: address)
    }

    static func address(wallet: ZanoWallet) throws -> String {
        try ZanoCore.address(wallet: wallet)
    }

    /// Zano core version compiled into the bundled xcframework, e.g. "2.2.1.505[<commit>]".
    /// Backed by plain_wallet::get_version(), which returns a compile-time constant, so this is
    /// safe to call before any wallet exists.
    static var coreVersion: String {
        // ZANO_PlainWallet_getVersion() returns a heap buffer; stringFromCString frees it.
        stringFromCString(ZANO_PlainWallet_getVersion()) ?? "unknown"
    }
}

// MARK: - Errors

public enum ZanoKitError: Error {
    case invalidWalletId
    case invalidSeed
    case notImplemented
}

// MARK: - Delegate Protocol

public protocol ZanoKitDelegate: AnyObject {
    func assetsDidChange(assets: [AssetInfo])
    func balancesDidChange(balances: [BalanceInfo])
    func transactionsDidChange(transactions: [TransactionInfo])
    func walletStateDidChange(state: WalletState)
}

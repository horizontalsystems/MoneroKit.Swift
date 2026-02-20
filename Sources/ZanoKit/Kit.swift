import Foundation
import HsToolKit

public class Kit {
    public static let confirmationsThreshold: UInt64 = 10

    private let zanoCore: ZanoCore
    private let storage: GrdbStorage
    private let kitId = UUID().uuidString
    private let lifecycleQueue = DispatchQueue(label: "io.horizontalsystems.zano_kit.kit_lifecycle_queue", qos: .background)
    private var started = false

    public weak var delegate: ZanoKitDelegate?

    public init(wallet: ZanoWallet, walletId: String, node: Node, networkType: NetworkType = .mainnet, reachabilityManager: ReachabilityManager, logger: Logger?, zanoCoreLogLevel: Int32? = nil) throws {
        let baseDirectoryName = "ZanoKit/\(walletId)/network_\(networkType.rawValue)"
        let baseDirectoryUrl = try FileHandler.directoryURL(for: baseDirectoryName)

        let databasePath = baseDirectoryUrl.appendingPathComponent("storage").path
        storage = GrdbStorage(databaseFilePath: databasePath)

        let walletDirectoryName = "\(baseDirectoryName)/zano_core"
        let walletDirectoryUrl = try FileHandler.directoryURL(for: walletDirectoryName)
        let walletPath = walletDirectoryUrl.appendingPathComponent("wallet").path
        let workingDir = walletDirectoryUrl.path

        let logger = logger ?? Logger(minLogLevel: .verbose)

        zanoCore = ZanoCore(
            wallet: wallet,
            walletPath: walletPath,
            workingDir: workingDir,
            walletPassword: walletId,
            node: node,
            networkType: networkType,
            reachabilityManager: reachabilityManager,
            logger: logger,
            zanoCoreLogLevel: zanoCoreLogLevel
        )

        zanoCore.delegate = self
    }

    deinit {
        _stop()
    }

    // MARK: - Public Properties

    public var lastBlockInfo: UInt64 {
        if let heights = zanoCore.blockHeights {
            return heights.0
        }
        return storage.getBlockHeights()?.walletHeight ?? 0
    }

    public var walletState: WalletState {
        zanoCore.state
    }

    public var balanceInfo: BalanceInfo {
        if let balance = storage.getBalance() {
            return BalanceInfo(balance: balance)
        }
        return BalanceInfo(all: 0, unlocked: 0)
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
        info.append(("Node", zanoCore.node.url.absoluteString))
        return info
    }

    public func transactions(fromHash: String? = nil, descending: Bool = true, type: TransactionFilterType? = nil, limit: Int? = nil) -> [TransactionInfo] {
        var fromTimestamp: Int? = nil
        if let fromHash {
            fromTimestamp = storage.transaction(byHash: fromHash)?.timestamp
        }

        return storage.transactions(fromTimestamp: fromTimestamp, descending: descending, type: type, limit: limit)
            .map { TransactionInfo(transaction: $0) }
    }

    // MARK: - Lifecycle Methods

    private func _start() {
        guard !started else { return }

        do {
            try zanoCore.start()
            started = true
        } catch {
            // Handle error
        }
    }

    private func _stop() {
        guard started else { return }
        zanoCore.stop()
        started = false
    }

    private func _restart() {
        _stop()
        _start()
    }

    public func start() {
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
    public func send(to address: String, amount: SendAmount, priority: SendPriority = .default, memo: String?) throws -> String {
        let fee = estimateFee(priority: priority)
        let amountValue: UInt64

        switch amount {
        case .value(let value):
            amountValue = UInt64(value)
        case .all:
            // For send all, use unlocked balance minus fee
            let balance = zanoCore.balance
            if balance.unlocked <= Int64(fee) {
                throw ZanoCoreError.insufficientFunds("0")
            }
            amountValue = UInt64(balance.unlocked) - fee
        }

        return try zanoCore.send(to: address, amount: amountValue, fee: fee, comment: memo)
    }

    public func estimateFee(priority: SendPriority = .default) -> UInt64 {
        ZanoWalletAPI.estimateFee(priority: UInt64(priority.rawValue))
    }
}

// MARK: - ZanoCoreDelegate

extension Kit: ZanoCoreDelegate {
    func balanceDidChange(balance: ZanoCore.Balance) {
        let balanceRecord = Balance(all: balance.all, unlocked: balance.unlocked)
        storage.update(balance: balanceRecord)
        delegate?.balanceDidChange(balanceInfo: BalanceInfo(balance: balanceRecord))
    }

    func transactionsDidChange(transactions: [ZanoCore.Transaction]) {
        let transactionRecords = transactions.map { tx in
            Transaction(
                hash: tx.hash,
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
        delegate?.transactionsUpdated(inserted: [], updated: transactionInfos)
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

    static func isValid(address: String, networkType: NetworkType) -> Bool {
        ZanoCore.isValid(address: address)
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
    func balanceDidChange(balanceInfo: BalanceInfo)
    func transactionsUpdated(inserted: [TransactionInfo], updated: [TransactionInfo])
    func walletStateDidChange(state: WalletState)
}

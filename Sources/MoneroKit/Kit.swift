import Foundation
import HsToolKit

public class Kit {
    public static let confirmationsThreshold: UInt64 = 10
    public static let lastBirthdayHeight: UInt64 = 3_479_151
    private let moneroCore: MoneroCore
    private let storage: GrdbStorage

    public weak var delegate: MoneroKitDelegate?

    public init(mnemonic: MoneroMnemonic, restoreHeight: UInt64 = 0, walletId: String, node: Node, networkType: NetworkType = .mainnet, logger: Logger?, moneroCoreLogLevel: Int32? = nil) throws {
        let baseDirectoryName = "MoneroKit/\(walletId)/network_\(networkType.rawValue)"
        let baseDirectoryUrl = try FileHandler.directoryURL(for: baseDirectoryName)

        let databasePath = baseDirectoryUrl.appendingPathComponent("storage").path
        storage = GrdbStorage(databaseFilePath: databasePath)

        let walletDirectoryName = "\(baseDirectoryName)/monero_core"
        if storage.getBlockHeights() == nil {
            try FileHandler.remove(for: walletDirectoryName)
        }

        let walletPath = try FileHandler.directoryURL(for: walletDirectoryName).appendingPathComponent("wallet").path
        let logger = logger ?? Logger(minLogLevel: .verbose)

        moneroCore = MoneroCore(
            mnemonic: mnemonic,
            walletPath: walletPath,
            walletPassword: walletId,
            node: node,
            restoreHeight: restoreHeight,
            networkType: networkType,
            logger: logger,
            moneroCoreLogLevel: moneroCoreLogLevel
        )

        moneroCore.delegate = self
    }

    public var restoreHeight: UInt64 {
        moneroCore.restoreHeight
    }

    public var balanceInfo: BalanceInfo {
        moneroCore.balance
    }

    public var walletState: WalletState {
        moneroCore.state
    }

    public var receiveAddress: String {
        moneroCore.receiveAddress
    }

    public func start() {
        try? moneroCore.start()
    }

    public func stop() {
        moneroCore.stop()
    }

    public func transactions(fromHash: String? = nil, descending: Bool, type: TransactionFilterType?, limit: Int?) -> [TransactionInfo] {
        var resolvedTimestamp: Int?

        if let fromHash, let transaction = storage.transaction(byHash: fromHash) {
            resolvedTimestamp = transaction.timestamp
        }

        return storage
            .transactions(fromTimestamp: resolvedTimestamp, descending: descending, type: type, limit: limit)
            .map { TransactionInfo(transaction: $0) }
    }

    public func send(to address: String, amount: SendAmount, priority: SendPriority = .default) throws {
        try moneroCore.send(to: address, amount: amount, priority: priority)
    }

    public func estimateFee(address: String, amount: SendAmount, priority: SendPriority = .default) throws -> UInt64 {
        try moneroCore.estimateFee(address: address, amount: amount, priority: priority)
    }
}

extension Kit: MoneroCoreDelegate {
    func walletStateDidChange(state: WalletState) {
        delegate?.walletStateDidChange(state: state)
        if let daemonHeight = state.daemonHeight, let walletBlockHeight = state.walletBlockHeight {
            storage.update(blockHeights: BlockHeights(daemonHeight: Int(daemonHeight), walletHeight: Int(walletBlockHeight)))
        }
    }

    func subAddresssesDidChange(subAddresses: [String]) {
        storage.update(subAddresses: subAddresses, account: 0)
    }

    func balanceDidChange(balanceInfo: BalanceInfo) {
        delegate?.balanceDidChange(balanceInfo: balanceInfo)
    }

    func transactionsDidChange(transactions: [MoneroCore.Transaction]) {
        let transactionRecords = transactions.compactMap { transaction in
            var type = transaction.direction == .in ? TransactionType.incoming : .outgoing
            var recipientAddress: String? = nil

            if let transfer = transaction.transfers.first {
                if storage.addressExists(transfer.address) {
                    recipientAddress = transfer.address
                    type = .sentToSelf
                }
            }

            return Transaction(
                hash: transaction.hash,
                type: type,
                blockHeight: transaction.blockHeight,
                amount: transaction.amount,
                fee: transaction.fee,
                isPending: transaction.isPending,
                isFailed: transaction.isFailed,
                timestamp: Int(transaction.timestamp.timeIntervalSince1970),
                recipientAddress: recipientAddress
            )
        }

        storage.update(transactions: transactionRecords)

        let transactionInfos = transactionRecords.map { TransactionInfo(transaction: $0) }
        delegate?.transactionsUpdated(inserted: [], updated: transactionInfos)
    }
}

public extension Kit {
    static func removeAll(except excludedFiles: [String]) throws {
        try FileHandler.removeAll(except: excludedFiles)
    }

    static func isValid(address: String, networkType: NetworkType) -> Bool {
        MoneroCore.isValid(address: address, networkType: networkType)
    }
}

public enum MoneroKitError: Error {
    case invalidWalletId
    case invalidSeed
}

public protocol MoneroKitDelegate: AnyObject {
    func balanceDidChange(balanceInfo: BalanceInfo)
    func transactionsUpdated(inserted: [TransactionInfo], updated: [TransactionInfo])
    func walletStateDidChange(state: WalletState)
}

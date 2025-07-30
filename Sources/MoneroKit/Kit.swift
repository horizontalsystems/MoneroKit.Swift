import Foundation

public class Kit {
    private let moneroCore: MoneroCore
    private let storage: GrdbStorage

    weak public var delegate: MoneroKitDelegate? = nil

    public init(mnemonic: MoneroMnemonic, restoreHeight: UInt64 = 0, walletId: String, daemonAddress: String, networkType: NetworkType = .mainnet) throws {
        let directoryUrl = try Self.directoryURL(for: "MoneroKit/\(walletId)-\(networkType.rawValue)")
        let walletPath = directoryUrl.appendingPathComponent("monero_core").path
        let databaseFilePath = directoryUrl.appendingPathComponent("storage").path

        moneroCore = MoneroCore(
            mnemonic: mnemonic,
            walletPath: walletPath,
            walletPassword: walletId,
            daemonAddress: daemonAddress,
            restoreHeight: restoreHeight,
            networkType: networkType
        )
        storage = GrdbStorage(databaseFilePath: databaseFilePath)

        moneroCore.delegate = self
    }

    public var daemonHeight: Int? {
        moneroCore.daemonHeight.map { Int($0) }
    }

    public var lastBlockHeight: Int? {
        moneroCore.lastBlockHeight.map { Int($0) }
    }

    public var balanceInfo: BalanceInfo {
        moneroCore.balance
    }

    public var isSynchronized: Bool {
        moneroCore.isSynchronized
    }

    public var walletStatus: WalletStatus {
        moneroCore.walletStatus
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

    public func transactions(fromUid: String? = nil, type: TransactionFilterType?, limit: Int? = nil) -> [TransactionInfo] {
        var resolvedTimestamp: Int? = nil

        if let fromUid, let transaction = storage.transaction(byUid: fromUid) {
            resolvedTimestamp = transaction.timestamp
        }

        return storage
            .transactions(fromTimestamp: resolvedTimestamp, type: type, limit: limit)
            .map { TransactionInfo(transaction: $0) }
    }

    public func send(to address: String, amount: Int) throws {
        try moneroCore.send(to: address, amount: amount)
    }

    public func estimateFee(amount: Int) -> UInt64 {
        moneroCore.estimateFee(amount: amount)
    }

    public func validate(address: String) -> Bool {
        moneroCore.validate(address: address)
    }
}

extension Kit: MoneroCoreDelegate {
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

    func walletStatusDidChange(status: WalletStatus) {
        delegate?.walletStatusDidChange(status: status)
    }

    func syncStateDidChange(isSynchronized: Bool) {
        delegate?.syncStateDidChange(isSynchronized: isSynchronized)
    }
    
    func lastBlockHeightDidChange(height: UInt64) {
        delegate?.lastBlockHeightDidChange(height: height)
    }
}

extension Kit {
    public static func directoryURL(for directoryName: String) throws -> URL {
        let fileManager = FileManager.default

        let url = try fileManager
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(directoryName, isDirectory: true)

        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)

        return url
    }
}

public enum MoneroKitError: Error {
    case invalidWalletId
    case invalidSeed
}

import Foundation
import HsToolKit

public class Kit {
    public static let confirmationsThreshold: UInt64 = 10
    public static let lastBirthdayHeight: UInt64 = 3_480_000

    private let moneroCore: MoneroCore
    private let storage: GrdbStorage
    private let kitId = UUID().uuidString
    private let lifecycleQueue = DispatchQueue(label: "io.horizontalsystems.monero_kit.kit_lifecycle_queue", qos: .background)
    private var started = false

    public weak var delegate: MoneroKitDelegate?

    public init(mnemonic: MoneroMnemonic, account: UInt32, restoreHeight: UInt64 = 0, walletId: String, node: Node, networkType: NetworkType = .mainnet, reachabilityManager: ReachabilityManager, logger: Logger?, moneroCoreLogLevel: Int32? = nil) throws {
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
            account: account,
            walletPath: walletPath,
            walletPassword: walletId,
            node: node,
            restoreHeight: restoreHeight,
            networkType: networkType,
            reachabilityManager: reachabilityManager,
            logger: logger,
            moneroCoreLogLevel: moneroCoreLogLevel
        )

        moneroCore.delegate = self

        if storage.getAllAddresses().isEmpty {
            let primaryAddress = try MoneroCore.address(mnemonic: mnemonic, account: account, index: 0, networkType: networkType)
            storage.add(subAddress: SubAddress(address: primaryAddress, index: 0))

            if account == 0 {
                let firstSubAddress = try MoneroCore.address(mnemonic: mnemonic, account: account, index: 1, networkType: networkType)
                storage.add(subAddress: SubAddress(address: firstSubAddress, index: 1))
            }
        }
    }

    deinit {
        _stop()
    }

    // Methods interacting with wallet cache in storage

    public var lastBlockInfo: UInt64 {
        guard let blockHeights = moneroCore.blockHeights else { return 0 }
        return blockHeights.0
    }

    public var walletState: WalletState {
        moneroCore.state
    }

    public var balanceInfo: BalanceInfo {
        let balanceRecord = storage.getBalance()
        return balanceRecord.map { BalanceInfo(balance: $0) } ?? .init(all: 0, unlocked: 0)
    }

    public var receiveAddress: String {
        storage.getLastUnusedAddress()?.address ?? ""
    }

    public var usedAddresses: [SubAddress] {
        storage.getAllAddresses()
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

    // Methods interacting with moneroCore

    private func _start() {
        guard !started else { return }
        started = true

        var kitState = KitManager.shared.checkAndGetInitialState(kitId: kitId)

        while kitState == .waiting {
            moneroCore.setConnectingState(waiting: true)
            Thread.sleep(forTimeInterval: 1.0)
            kitState = KitManager.shared.checkAndGetState(kitId: kitId)
        }

        if kitState == .running {
            moneroCore.setConnectingState(waiting: false)
            moneroCore.start()
        }
    }

    private func _stop() {
        guard started else { return }
        started = false

        moneroCore.stop()
        KitManager.shared.removeRunning(kitId: kitId)
    }

    private func _restart() {
        if case .idle = moneroCore.state { return }

        _stop()

        if !KitManager.shared.waitingKitExists() {
            _start()
        }
    }

    public func start() {
        lifecycleQueue.async { [weak self] in self?._start() }
    }

    public func stop() {
        lifecycleQueue.async { [weak self] in self?._stop() }
    }

    public func refresh() {
        guard KitManager.shared.isRunning(kitId: kitId) else { return }

        switch moneroCore.state {
        case .connecting, .syncing, .synced: moneroCore.refresh()
        case .notSynced: restart()
        case .idle: ()
        }
    }

    public func restart() {
        lifecycleQueue.async { [weak self] in self?._restart() }
    }

    public func send(to address: String, amount: SendAmount, priority: SendPriority = .default, memo: String?) throws {
        try moneroCore.send(to: address, amount: amount, priority: priority, memo: memo)
    }

    public func estimateFee(address: String, amount: SendAmount, priority: SendPriority = .default) throws -> UInt64 {
        try moneroCore.estimateFee(address: address, amount: amount, priority: priority)
    }
}

extension Kit: MoneroCoreDelegate {
    func walletStateDidChange(state: WalletState) {
        delegate?.walletStateDidChange(state: state)

        if case .notSynced = state {
            stop()
        }

        if let (walletHeight, daemonHeight) = moneroCore.blockHeights {
            storage.update(blockHeights: BlockHeights(daemonHeight: Int(daemonHeight), walletHeight: Int(walletHeight)))
        }
    }

    func subAddresssesDidChange(subAddresses: [MoneroCore.SubAddress]) {
        let subAddresses = subAddresses.map { SubAddress(address: $0.address, index: $0.index) }
        if !subAddresses.isEmpty {
            storage.update(subAddresses: subAddresses)
            delegate?.subAddressesUpdated(subaddresses: subAddresses)
        }
    }

    func balanceDidChange(balance: MoneroCore.Balance) {
        let balanceRecord = Balance(all: balance.all, unlocked: balance.unlocked)
        storage.update(balance: balanceRecord)
        delegate?.balanceDidChange(balanceInfo: BalanceInfo(balance: balanceRecord))
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
                note: transaction.note,
                recipientAddress: recipientAddress
            )
        }

        storage.update(transactions: transactionRecords)

        let transactionInfos = transactionRecords.map { TransactionInfo(transaction: $0) }
        delegate?.transactionsUpdated(inserted: [], updated: transactionInfos)

        // Mark used addresses
        var usedAddresses: [Int: Int] = Dictionary()
        for transaction in transactions {
            guard transaction.direction == .in else { continue }
            for index in transaction.subaddrIndices {
                usedAddresses[index] = (usedAddresses[index] ?? 0) + 1
            }
        }

        for (index, txCount) in usedAddresses {
            storage.setAddressTransactionsCount(index: index, txCount: txCount)
        }

        // Generate extra unused addresses
        if let lastUsedAddressIndex = usedAddresses.keys.max() {
            // We assume that there's at least 2 addresses in storage. Even if there's no transactions.
            let extraAddress = moneroCore.address(index: lastUsedAddressIndex + 1)
            storage.add(subAddress: SubAddress(address: extraAddress, index: lastUsedAddressIndex + 1))
        }
    }
}

public extension Kit {
    static func removeAll(except excludedFiles: [String]) throws {
        try FileHandler.removeAll(except: excludedFiles)
    }

    static func isValid(address: String, networkType: NetworkType) -> Bool {
        MoneroCore.isValid(address: address, networkType: networkType)
    }

    static func key(mnemonic: MoneroMnemonic, privateKey: Bool, spendKey: Bool) throws -> String? {
        try MoneroCore.key(mnemonic: mnemonic, privateKey: privateKey, spendKey: spendKey)
    }
}

public enum MoneroKitError: Error {
    case invalidWalletId
    case invalidSeed
}

public protocol MoneroKitDelegate: AnyObject {
    func balanceDidChange(balanceInfo: BalanceInfo)
    func subAddressesUpdated(subaddresses: [SubAddress])
    func transactionsUpdated(inserted: [TransactionInfo], updated: [TransactionInfo])
    func walletStateDidChange(state: WalletState)
}

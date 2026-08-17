import CMonero // for MONERO_VERSION_getFull() in coreVersion
import Combine
import Foundation
import HsToolKit
import UIKit

public class Kit {
    public static let confirmationsThreshold: UInt64 = 10

    private let moneroCore: MoneroCore
    private let storage: GrdbStorage
    private let kitId = UUID().uuidString
    private let lifecycleQueue = DispatchQueue(label: "io.horizontalsystems.monero_kit.kit_lifecycle_queue", qos: .utility)
    private let walletDirectoryName: String
    private var started = false
    private var cancellables = Set<AnyCancellable>()
    private var handledForegroundFromExpiredBackground = false

    public weak var delegate: MoneroKitDelegate?

    public init(wallet: MoneroWallet, account: UInt32, restoreHeight: UInt64 = 0, walletId: String, node: Node, networkType: NetworkType = .mainnet, reachabilityManager: ReachabilityManager, logger: Logger?, moneroCoreLogLevel: Int32? = nil) throws {
        let baseDirectoryName = "MoneroKit/\(walletId)/network_\(networkType.rawValue)"
        let baseDirectoryUrl = try FileHandler.directoryURL(for: baseDirectoryName)

        let databasePath = baseDirectoryUrl.appendingPathComponent("storage").path
        storage = GrdbStorage(databaseFilePath: databasePath)

        walletDirectoryName = "\(baseDirectoryName)/monero_core"
        if storage.getBlockHeights() == nil {
            try FileHandler.remove(for: walletDirectoryName)
        }

        let walletPath = try FileHandler.directoryURL(for: walletDirectoryName).appendingPathComponent("wallet").path
        let logger = logger ?? Logger(minLogLevel: .verbose)

        moneroCore = MoneroCore(
            wallet: wallet,
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

        if storage.getAllAddresses(accountIndex: Int(account)).isEmpty {
            let primaryAddress = try MoneroCore.address(wallet: wallet, account: account, index: 0, networkType: networkType)
            storage.add(subAddress: SubAddress(address: primaryAddress, index: 0, accountIndex: Int(account)))

            if account == 0 {
                if case .watch = wallet {
                    return
                }

                let firstSubAddress = try MoneroCore.address(wallet: wallet, account: account, index: 1, networkType: networkType)
                storage.add(subAddress: SubAddress(address: firstSubAddress, index: 1, accountIndex: Int(account)))
            }
        }

        subscribeToBackgroundNotifications()
    }

    private func subscribeToBackgroundNotifications() {
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                self?.handleDidEnterBackground()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.handleDidBecomeActive()
            }
            .store(in: &cancellables)

        BackgroundModeObserver.shared.foregroundFromExpiredBackgroundPublisher
            .sink { [weak self] in
                self?.handleForegroundFromExpiredBackground()
            }
            .store(in: &cancellables)
    }

    private func handleDidEnterBackground() {
        lifecycleQueue.async { [weak self] in
            guard let self, started else { return }
            handledForegroundFromExpiredBackground = false
            moneroCore.pause()
        }
    }

    private func handleForegroundFromExpiredBackground() {
        lifecycleQueue.async { [weak self] in
            guard let self, started else { return }
            handledForegroundFromExpiredBackground = true
            _restart()
        }
    }

    private func handleDidBecomeActive() {
        lifecycleQueue.async { [weak self] in
            guard let self, started else { return }
            if !handledForegroundFromExpiredBackground {
                moneroCore.resume()
            }
        }
    }

    deinit {
        let moneroCore = moneroCore
        let kitId = kitId
        let started = started

        lifecycleQueue.async {
            guard started else { return }

            moneroCore.stop()
            KitManager.shared.removeRunning(kitId: kitId)
        }
    }

    // Methods interacting with wallet cache in storage

    public var lastBlockInfo: UInt64 {
        var walletHeight = moneroCore.blockHeights?.0
        if walletHeight == nil {
            walletHeight = storage.getBlockHeights().map { UInt64($0.walletHeight) }
        }

        return walletHeight ?? 0
    }

    public var walletState: WalletState {
        moneroCore.state
    }

    public var balanceInfo: BalanceInfo {
        let balanceRecord = storage.getBalance()
        return balanceRecord.map { BalanceInfo(balance: $0) } ?? .init(all: 0, unlocked: 0)
    }

    public var receiveAddress: String {
        storage.getLastUnusedAddress(accountIndex: Int(activeAccount))?.address ?? ""
    }

    public var usedAddresses: [SubAddress] {
        storage.getAllAddresses(accountIndex: Int(activeAccount))
    }

    public var activeAccount: UInt32 {
        moneroCore.account
    }

    public var accounts: [AccountInfo] {
        storage.getAccounts().map {
            AccountInfo(index: UInt32($0.index), label: $0.label, balance: BalanceInfo(all: $0.all, unlocked: $0.unlocked))
        }
    }

    /// Switches which account balances, addresses and transactions are reported for.
    /// The wallet scans all accounts in a single refresh pass, so no restart or rescan happens.
    public func setActiveAccount(_ index: UInt32) {
        guard index != moneroCore.account else { return }

        moneroCore.setActiveAccount(index)

        // Re-emit the stored balance of the new account right away; the refresh triggered
        // by the switch confirms it against the wallet shortly after.
        let stored = storage.getAccounts().first { $0.index == Int(index) }
        let balanceRecord = Balance(all: UInt64(clamping: stored?.all ?? 0), unlocked: UInt64(clamping: stored?.unlocked ?? 0))
        storage.update(balance: balanceRecord)

        // Make sure the account has at least its primary address so receiveAddress works
        // before the first refresh completes.
        if storage.getAllAddresses(accountIndex: Int(index)).isEmpty {
            let primaryAddress = moneroCore.address(index: 0)
            if !primaryAddress.isEmpty {
                storage.add(subAddress: SubAddress(address: primaryAddress, index: 0, accountIndex: Int(index)))
            }
        }

        // Emissions ride the same serial event queue as every other delegate callback, so
        // they can never overlap kit-driven emissions on another thread.
        moneroCore.globalEventQueue.async { [weak self] in
            guard let self else { return }
            delegate?.balanceDidChange(balanceInfo: BalanceInfo(balance: balanceRecord))
            delegate?.accountsUpdated(accounts: accounts)
            delegate?.transactionsUpdated(inserted: [], updated: transactions(descending: true, type: nil, limit: nil))
        }
    }

    public func createAccount(label: String? = nil) throws -> AccountInfo {
        try moneroCore.createAccount(label: label)
    }

    public func setAccountLabel(accountIndex: UInt32, label: String) throws {
        try moneroCore.setAccountLabel(accountIndex: accountIndex, label: label)
    }

    public var statusInfo: [(String, Any)] {
        var status = [(String, Any)]()

        let (walletHeight, daemonHeight) = moneroCore.blockHeights.map { ("\($0)", "\($1)") } ?? ("n/a", "n/a")
        let lastSyncedWalletHeight = storage.getBlockHeights().map { "\($0.walletHeight)" } ?? "n/a"
        status.append(("Wallet Status", walletState.description))
        status.append(("Last Block Height", "\(lastBlockInfo)"))
        status.append(("Last Synced Wallet Height", lastSyncedWalletHeight))
        status.append(("Wallet Height", walletHeight))
        status.append(("Daemon Height", daemonHeight))
        status.append(("Kit started", started ? "yes" : "no"))
        status.append(("Node", moneroCore.node.description))

        return status
    }

    public func transactions(fromHash: String? = nil, descending: Bool, type: TransactionFilterType?, limit: Int?) -> [TransactionInfo] {
        var resolvedTimestamp: Int?

        if let fromHash, let transaction = storage.transaction(byHash: fromHash) {
            resolvedTimestamp = transaction.timestamp
        }

        return storage
            .transactions(fromTimestamp: resolvedTimestamp, descending: descending, type: type, limit: limit, accountIndex: Int(activeAccount))
            .map { TransactionInfo(transaction: $0, privateTxData: storage.getPrivateTxData(byHash: $0.hash)) }
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
            do {
                try moneroCore.start()
            } catch {
                if let coreError = error as? MoneroCoreError, case .restoreHeightDontMatch = coreError {
                    do {
                        try FileHandler.remove(for: walletDirectoryName)
                        _ = try FileHandler.directoryURL(for: walletDirectoryName).appendingPathComponent("wallet").path

                        storage.clearStorage()
                        try moneroCore.start()
                        delegate?.balanceDidChange(balanceInfo: balanceInfo)
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
        moneroCore.setConnectingState(waiting: false)
        lifecycleQueue.async { [weak self] in self?._start() }
    }

    public func stop() {
        lifecycleQueue.async { [weak self] in self?._stop() }
    }

    public func refresh() {
        lifecycleQueue.async { [weak self] in
            guard let self,
                  started,
                  KitManager.shared.isRunning(kitId: self.kitId) else { return }

            switch moneroCore.state {
            case .connecting, .syncing, .synced: moneroCore.refresh()
            case .notSynced: restart()
            case .idle: ()
            }
        }
    }

    public func restart() {
        lifecycleQueue.async { [weak self] in self?._restart() }
    }

    /// Outputs spendable by the active account. Enumeration takes the wallet2 mutex, which the
    /// background refresh thread can hold for seconds - do not call from the main thread.
    public func unspentOutputs() throws -> [UnspentOutput] {
        try moneroCore.unspentOutputs()
    }

    @discardableResult public func send(to address: String, amount: SendAmount, priority: SendPriority = .default, memo: String?, selectedKeyImages: [String]? = nil) throws -> [String] {
        let result = try moneroCore.send(to: address, amount: amount, priority: priority, memo: memo, selectedKeyImages: selectedKeyImages)

        for (index, txHash) in result.txHashes.enumerated() {
            if index < result.txKeys.count {
                let privateTxData = PrivateTxData(txHash: txHash, txKey: result.txKeys[index], recipientAddress: result.recipientAddress)
                storage.savePrivateTxData(privateTxData)
            }
        }

        return result.txHashes
    }

    public func estimateFee(address: String, amount: SendAmount, priority: SendPriority = .default) throws -> UInt64 {
        try moneroCore.estimateFee(address: address, amount: amount, priority: priority)
    }
}

extension Kit: MoneroCoreDelegate {
    func walletStateDidChange(state: WalletState) {
        delegate?.walletStateDidChange(state: state)

        if let (walletHeight, daemonHeight) = moneroCore.blockHeights {
            storage.update(blockHeights: BlockHeights(daemonHeight: Int(daemonHeight), walletHeight: Int(walletHeight)))
        }
    }

    func subAddresssesDidChange(subAddresses: [MoneroCore.SubAddress], account: UInt32) {
        if account == 0, subAddresses.count <= 1 {
            // 0 account must keep 2 addresses created on Kit initialization
            return
        } else if subAddresses.count == 0 {
            // > 0 accounts must keep 1 address created on Kit initialization
            return
        }

        let subAddresses = subAddresses.map { SubAddress(address: $0.address, index: $0.index, accountIndex: Int($0.accountIndex)) }
        storage.update(subAddresses: subAddresses, accountIndex: Int(account))

        if account == moneroCore.account {
            delegate?.subAddressesUpdated(subaddresses: subAddresses)
        }
    }

    func accountsDidChange(accounts: [AccountInfo]) {
        storage.update(accounts: accounts.map {
            Account(index: Int($0.index), label: $0.label, all: UInt64(clamping: $0.balance.all), unlocked: UInt64(clamping: $0.balance.unlocked))
        })
        delegate?.accountsUpdated(accounts: accounts)
    }

    func balanceDidChange(balance: MoneroCore.Balance) {
        let balanceRecord = Balance(all: balance.all, unlocked: balance.unlocked)
        storage.update(balance: balanceRecord)
        delegate?.balanceDidChange(balanceInfo: BalanceInfo(balance: balanceRecord))
    }

    func transactionsDidChange(transactions: [MoneroCore.Transaction]) {
        let transactionRecords = transactions.compactMap { transaction in
            let type = transaction.direction == .in ? TransactionType.incoming : .outgoing
            var recipientAddress: String? = nil

            if type == .incoming,
               let subAddressIndex = transaction.subaddrIndices.first,
               let address = storage.getAddress(index: subAddressIndex, accountIndex: Int(transaction.subaddrAccount))
            {
                recipientAddress = address.address
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
                recipientAddress: recipientAddress,
                accountIndex: Int(transaction.subaddrAccount)
            )
        }

        storage.update(transactions: transactionRecords)

        let activeAccount = Int(moneroCore.account)
        let transactionInfos = transactionRecords
            .filter { $0.accountIndex == activeAccount }
            .map { TransactionInfo(transaction: $0, privateTxData: storage.getPrivateTxData(byHash: $0.hash)) }
        delegate?.transactionsUpdated(inserted: [], updated: transactionInfos)

        // Mark used addresses, per account
        var usedAddresses: [Int: [Int: Int]] = [:]
        for transaction in transactions {
            guard transaction.direction == .in else { continue }
            for index in transaction.subaddrIndices {
                usedAddresses[Int(transaction.subaddrAccount), default: [:]][index, default: 0] += 1
            }
        }

        for (accountIndex, counts) in usedAddresses {
            for (index, txCount) in counts {
                storage.setAddressTransactionsCount(index: index, accountIndex: accountIndex, txCount: txCount)
            }
        }

        // Generate extra unused addresses for the active account
        if let lastUsedAddressIndex = usedAddresses[activeAccount]?.keys.max() {
            // We assume that there's at least 2 addresses in storage. Even if there's no transactions.
            let extraAddress = moneroCore.address(index: lastUsedAddressIndex + 1)
            if !extraAddress.isEmpty {
                storage.add(subAddress: SubAddress(address: extraAddress, index: lastUsedAddressIndex + 1, accountIndex: activeAccount))
            }
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

    static func isValid(viewKey: String, address: String, isViewKey: Bool, networkType: NetworkType) -> Bool {
        MoneroCore.isValid(viewKey: viewKey, address: address, isViewKey: isViewKey, networkType: networkType)
    }

    static func key(wallet: MoneroWallet, privateKey: Bool, spendKey: Bool) throws -> String? {
        try MoneroCore.key(wallet: wallet, privateKey: privateKey, spendKey: spendKey)
    }

    static func address(wallet: MoneroWallet, account: UInt32, index: UInt32) throws -> String? {
        try MoneroCore.address(wallet: wallet, account: account, index: index, networkType: .mainnet)
    }

    /// Monero core version compiled into the bundled xcframework, e.g. "0.18.5.1-c1b843525".
    /// Read from the native library itself, so it cannot drift from the binary actually in use.
    static var coreVersion: String {
        guard let cString = MONERO_VERSION_getFull() else { return "unknown" }
        // Static string owned by the library - must not be freed.
        return String(cString: cString)
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
    func accountsUpdated(accounts: [AccountInfo])
}

public extension MoneroKitDelegate {
    // Optional: only delegates interested in multi-account state need to implement it.
    func accountsUpdated(accounts _: [AccountInfo]) {}
}

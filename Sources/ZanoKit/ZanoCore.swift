import Combine
import Foundation
import HsToolKit

class ZanoCore {
    weak var delegate: ZanoCoreDelegate?

    private let globalEventQueue = DispatchQueue.global(qos: .background)
    private let walletQueue = DispatchQueue(label: "io.horizontalsystems.zano_kit.wallet_queue", qos: .background)

    private var wallet: ZanoWallet
    private var stateManager: SyncStateManager
    private var networkType: NetworkType = .mainnet
    private let logger: Logger?
    private let api: ZanoWalletAPI
    private let walletPath: String
    private let walletPassword: String
    private let workingDir: String
    private let zanoCoreLogLevel: Int32

    // Zano uses wallet_id (int64) instead of pointer
    private(set) var walletId: Int64?
    var node: Node

    private var transactions: [Transaction] = [] {
        didSet {
            globalEventQueue.async { [weak self] in
                guard let self else { return }
                delegate?.transactionsDidChange(transactions: transactions)
            }
        }
    }

    private(set) var balance: Balance = .init(all: 0, unlocked: 0) {
        didSet {
            globalEventQueue.async { [weak self] in
                guard let self else { return }
                if oldValue != balance {
                    delegate?.balanceDidChange(balance: balance)
                }
            }
        }
    }

    private(set) var walletAddress: String = ""

    var state: WalletState {
        stateManager.state
    }

    var blockHeights: (UInt64, UInt64)? {
        stateManager.blockHeights
    }

    init(wallet: ZanoWallet, walletPath: String, workingDir: String, walletPassword: String, node: Node, networkType: NetworkType, reachabilityManager: ReachabilityManager, logger: Logger?, zanoCoreLogLevel: Int32?) {
        self.wallet = wallet
        self.walletPath = walletPath
        self.workingDir = workingDir
        self.walletPassword = walletPassword
        self.node = node
        self.networkType = networkType
        self.logger = logger
        self.zanoCoreLogLevel = zanoCoreLogLevel ?? 0
        self.api = ZanoWalletAPI(logger: logger)
        stateManager = SyncStateManager(api: api, logger: logger, restoreHeight: 0, reachabilityManager: reachabilityManager)

        stateManager.onSyncStateChanged = { [weak self] in
            self?.onSyncStateChanged()
        }
    }

    deinit {
        wallet.clear()
    }

    // MARK: - Wallet Operations

    private func initializeLibrary() throws {
        let daemonAddress = node.url.absoluteString
        let _ = api.initLibrary(daemonAddress: daemonAddress, workingDir: workingDir, logLevel: zanoCoreLogLevel)
    }

    private func openOrRestoreWallet() throws {
        let walletExists = api.walletExists(path: walletPath)

        let resultJson: String?

        if walletExists {
            resultJson = api.openWallet(path: walletPath, password: walletPassword)
        } else {
            logger?.debug("Restoring wallet to: \(walletPath)")

            switch wallet {
            case .bip39(let words, let passphrase, let creationTimestamp):
                resultJson = try restoreFromBip39(words: words, passphrase: passphrase, creationTimestamp: creationTimestamp)

            case .legacy(let words, let passphrase):
                let seed = words.joined(separator: " ")
                resultJson = api.restoreWallet(
                    seed: seed,
                    path: walletPath,
                    password: walletPassword,
                    passphrase: passphrase,
                    seedWordsCount: words.count
                )
            }
        }

        guard let json = resultJson else {
            throw ZanoCoreError.walletRecoveryFailed("No response from wallet")
        }

        // Parse the response to get wallet_id and address
        guard let data = json.data(using: .utf8),
              let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = response["result"] as? [String: Any] else {
            // Check for error
            if let data = json.data(using: .utf8),
               let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = response["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw ZanoCoreError.walletRecoveryFailed(message)
            }
            throw ZanoCoreError.walletRecoveryFailed("Failed to parse wallet response")
        }

        guard let walletIdValue = result["wallet_id"] as? Int64 else {
            throw ZanoCoreError.walletRecoveryFailed("No wallet_id in response")
        }

        walletId = walletIdValue

        // Extract address from wi (wallet info)
        if let wi = result["wi"] as? [String: Any],
           let address = wi["address"] as? String {
            walletAddress = address
            logger?.debug("Wallet address: \(address)")

            // Parse initial balance
            if let balances = wi["balances"] as? [[String: Any]] {
                parseBalances(balances)
            }
        }

        wallet.clear()
        logger?.debug("Wallet opened with id: \(walletIdValue)")
    }

    private func restoreFromBip39(words: [String], passphrase: String, creationTimestamp: UInt64) throws -> String? {
        // Derive 32-byte secret from BIP39 mnemonic
        let secretDerivation = try secretDerivationFromBip39(mnemonic: words, passphrase: passphrase)

        logger?.debug("Restoring wallet from BIP39 derivation")
        logger?.debug("   Words count: \(words.count)")
        logger?.debug("   Passphrase: \(passphrase.isEmpty ? "(empty)" : "(provided)")")
        logger?.debug("   Creation timestamp: \(creationTimestamp)")

        // Convert timestamp to human-readable date for logging
        let date = Date(timeIntervalSince1970: TimeInterval(creationTimestamp))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        logger?.debug("   Creation date (UTC): \(formatter.string(from: date))")

        // Build params for restore_from_derivations
        let params: [String: Any] = [
            "pass": walletPassword,
            "path": walletPath,
            "secret_derivation": secretDerivation,
            "is_auditable": false,
            "creation_timestamp": creationTimestamp
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: params, options: .sortedKeys),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw ZanoCoreError.walletRecoveryFailed("Failed to build restore params")
        }

        // Build masked params for logging
        let logParams: [String: Any] = [
            "pass": "***",
            "path": walletPath,
            "secret_derivation": "\(secretDerivation.prefix(8))...\(secretDerivation.suffix(8))",
            "is_auditable": false,
            "creation_timestamp": creationTimestamp
        ]
        let logString: String?
        if let logData = try? JSONSerialization.data(withJSONObject: logParams, options: [.prettyPrinted, .sortedKeys]) {
            logString = String(data: logData, encoding: .utf8)
        } else {
            logString = nil
        }

        return api.syncCall(
            method: "restore_from_derivations",
            instanceId: 0,
            params: jsonString,
            logParams: logString
        )
    }

    private func parseBalances(_ balances: [[String: Any]]) {
        // Find native ZANO balance
        for balanceInfo in balances {
            if let assetInfo = balanceInfo["asset_info"] as? [String: Any],
               let ticker = assetInfo["ticker"] as? String,
               ticker == "ZANO" {
                let total = balanceInfo["total"] as? Int64 ?? 0
                let unlocked = balanceInfo["unlocked"] as? Int64 ?? 0
                balance = Balance(all: total, unlocked: unlocked)
                return
            }
        }
    }

    private func onSyncStateChanged() {
        globalEventQueue.async { [weak self] in
            guard let self else { return }
            delegate?.walletStateDidChange(state: state)
        }

        switch state {
        case .connecting, .notSynced: ()

        case .synced:
            walletQueue.async { [weak self] in
                self?.refresh()
                self?.storeWallet()
            }

        case .syncing:
            if stateManager.chunkOfBlocksSynced {
                walletQueue.async { [weak self] in
                    self?.refresh()
                    self?.storeWallet()
                    self?.stateManager.walletStored()
                }
            }

        case let .idle(daemonReachable):
            if daemonReachable {
                startWalletServices()
            } else {
                stopWalletServices()
            }
        }
    }

    private func storeWallet() {
        guard let wid = walletId else { return }
        let _ = api.invoke(walletId: wid, method: "store")
    }

    func updateBalance() {
        guard let wid = walletId else { return }

        // Skip if wallet is busy with long refresh
        if stateManager.isInLongRefresh {
            return
        }

        guard let resultJson = api.invoke(walletId: wid, method: "getbalance") else { return }

        let (result, _) = api.parseResponse(resultJson)
        guard let result = result else { return }

        if let balances = result["balances"] as? [[String: Any]] {
            parseBalances(balances)
        } else {
            // Fallback to simple balance fields
            let all = result["balance"] as? Int64 ?? 0
            let unlocked = result["unlocked_balance"] as? Int64 ?? 0
            balance = Balance(all: all, unlocked: unlocked)
        }
    }

    func fetchTransactions() {
        guard let wid = walletId else { return }

        // Skip fetching if wallet is busy with long refresh
        if stateManager.isInLongRefresh {
            logger?.debug("Skipping fetch transactions - wallet is in long refresh")
            return
        }

        let params: [String: Any] = [
            "offset": 0,
            "count": 1000,
            "update_provision_info": true
        ]

        guard let resultJson = api.invoke(walletId: wid, method: "get_recent_txs_and_info", params: params) else {
            logger?.debug("Fetch transactions: no response (wallet may be busy)")
            return
        }

        let (result, error) = api.parseResponse(resultJson)

        if let error = error {
            logger?.debug("Fetch transactions error: \(error.code) - \(error.message)")
            return
        }

        guard let result = result else {
            // No result might just mean no transactions yet
            return
        }

        var fetchedTransactions: [Transaction] = []

        if let transfers = result["transfers"] as? [[String: Any]] {
            for tx in transfers {
                guard let txHash = tx["tx_hash"] as? String else { continue }

                let isIncome = tx["is_income"] as? Bool ?? false
                let amount = tx["amount"] as? Int64 ?? 0
                let fee = tx["fee"] as? UInt64 ?? 0
                let height = tx["height"] as? UInt64 ?? 0
                let timestamp = tx["timestamp"] as? Int ?? 0
                let comment = tx["comment"] as? String

                // Determine remote address
                var remoteAddress: String? = nil
                if let remoteAddresses = tx["remote_addresses"] as? [String], !remoteAddresses.isEmpty {
                    remoteAddress = remoteAddresses.first
                }

                let type: TransactionType = isIncome ? .incoming : .outgoing

                let transaction = Transaction(
                    hash: txHash,
                    type: type,
                    blockHeight: height,
                    amount: isIncome ? amount : -amount,
                    fee: fee,
                    isPending: height == 0,
                    isFailed: false,
                    timestamp: timestamp,
                    note: comment,
                    recipientAddress: remoteAddress
                )

                fetchedTransactions.append(transaction)
            }
        }

        transactions = fetchedTransactions.sorted { $0.timestamp > $1.timestamp }
    }

    private func startWalletServices() {
        guard let wid = walletId else { return }
        stateManager.state = .connecting(waiting: false)
        stateManager.start(walletId: wid)
    }

    private func stopWalletServices() {
        stateManager.stop()
    }

    // MARK: - Public Methods

    func start() throws {
        try initializeLibrary()
        try openOrRestoreWallet()
        stateManager.validateReachable()
        startWalletServices()
    }

    func stop() {
        stopWalletServices()

        guard let wid = walletId else { return }
        let _ = api.closeWallet(walletId: wid)
        walletId = nil
    }

    func refresh() {
        updateBalance()
        fetchTransactions()
    }

    // MARK: - Send Transaction

    func send(to address: String, amount: UInt64, fee: UInt64, mixin: Int = 10, comment: String?) throws -> String {
        guard let wid = walletId else {
            throw ZanoCoreError.walletNotInitialized
        }

        // Build the transfer params
        var transferParams: [String: Any] = [
            "destinations": [
                ["address": address, "amount": amount]
            ],
            "fee": fee,
            "mixin": mixin
        ]

        // Add comment if provided
        if let comment = comment, !comment.isEmpty {
            transferParams["comment"] = comment
        }

        guard let resultJson = api.invoke(walletId: wid, method: "transfer", params: transferParams) else {
            throw ZanoCoreError.transactionSendFailed("No response from wallet")
        }

        let (result, error) = api.parseResponse(resultJson)

        if let error = error {
            if let matchedError = ZanoCoreError.match(error.message) {
                throw matchedError
            }
            throw ZanoCoreError.transactionSendFailed(error.message)
        }

        guard let result = result, let txHash = result["tx_hash"] as? String else {
            throw ZanoCoreError.transactionSendFailed("No transaction hash in response")
        }

        // Refresh to update balance and transactions
        walletQueue.async { [weak self] in
            self?.refresh()
        }

        return txHash
    }

    // MARK: - Static Methods

    static func isValid(address: String) -> Bool {
        let api = ZanoWalletAPI(logger: nil)
        return api.isValidAddress(address)
    }

    // MARK: - Internal Types

    struct Transaction {
        let hash: String
        let type: TransactionType
        let blockHeight: UInt64
        let amount: Int64
        let fee: UInt64
        let isPending: Bool
        let isFailed: Bool
        let timestamp: Int
        let note: String?
        let recipientAddress: String?
    }

    struct Balance: Equatable {
        let all: Int64
        let unlocked: Int64

        init(all: Int64, unlocked: Int64) {
            self.all = all
            self.unlocked = unlocked
        }

        static func == (lhs: Balance, rhs: Balance) -> Bool {
            lhs.all == rhs.all && lhs.unlocked == rhs.unlocked
        }
    }
}

protocol ZanoCoreDelegate: AnyObject {
    func balanceDidChange(balance: ZanoCore.Balance)
    func transactionsDidChange(transactions: [ZanoCore.Transaction])
    func walletStateDidChange(state: WalletState)
}

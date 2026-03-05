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
    private let storedCreationTimestamp: UInt64?
    private let onFirstRestore: ((UInt64) -> Void)?

    // Zano uses wallet_id (int64) instead of pointer
    private(set) var walletId: Int64?
    var daemonAddress: String

    // In-memory map of sent transfer info keyed by txHash.
    // Kit populates this from GRDB on init and updates it after each send.
    var sentTransfersMap: [String: SendResult] = [:]

    private var assets: [Asset] = []
    private var balances: [AssetBalance] = []
    private var transactions: [Transaction] = []

    /// Update assets only if changed, then notify delegate
    private func updateAssets(_ newAssets: [Asset]) {
        guard assets != newAssets else { return }
        assets = newAssets
        globalEventQueue.async { [weak self] in
            guard let self else { return }
            delegate?.assetsDidChange(assets: assets)
        }
    }

    /// Update balances only if changed, then notify delegate
    private func updateBalances(_ newBalances: [AssetBalance]) {
        guard balances != newBalances else { return }
        balances = newBalances
        globalEventQueue.async { [weak self] in
            guard let self else { return }
            delegate?.balancesDidChange(balances: balances)
        }
    }

    /// Update transactions only if changed, then notify delegate
    private func updateTransactions(_ newTransactions: [Transaction]) {
        guard transactions != newTransactions else { return }
        transactions = newTransactions
        globalEventQueue.async { [weak self] in
            guard let self else { return }
            delegate?.transactionsDidChange(transactions: transactions)
        }
    }

    private(set) var walletAddress: String = ""

    var state: WalletState {
        stateManager.state
    }

    var blockHeights: (UInt64, UInt64)? {
        stateManager.blockHeights
    }

    init(wallet: ZanoWallet, walletPath: String, workingDir: String, walletPassword: String, daemonAddress: String, networkType: NetworkType, reachabilityManager: ReachabilityManager, logger: Logger?, zanoCoreLogLevel: Int32?, storedCreationTimestamp: UInt64?, onFirstRestore: ((UInt64) -> Void)?) {
        self.wallet = wallet
        self.walletPath = walletPath
        self.workingDir = workingDir
        self.walletPassword = walletPassword
        self.daemonAddress = daemonAddress
        self.networkType = networkType
        self.logger = logger
        self.zanoCoreLogLevel = zanoCoreLogLevel ?? 0
        self.storedCreationTimestamp = storedCreationTimestamp
        self.onFirstRestore = onFirstRestore
        api = ZanoWalletAPI(logger: logger)

        stateManager = SyncStateManager(api: api, logger: logger, restoreHeight: wallet.restoreHeight, reachabilityManager: reachabilityManager)

        stateManager.onSyncStateChanged = { [weak self] in
            self?.onSyncStateChanged()
        }

        stateManager.onSyncedPoll = { [weak self] in
            self?.walletQueue.async {
                self?.refresh()
            }
        }

        stateManager.onBlockHeightsChanged = { [weak self] _, _ in
            self?.globalEventQueue.async { [weak self] in
                guard let self else { return }
                delegate?.walletStateDidChange(state: state)
            }
        }
    }

    deinit {
        wallet.clear()
    }

    // MARK: - Wallet Operations

    private func initializeLibrary() throws {
        _ = api.initLibrary(daemonAddress: daemonAddress, workingDir: workingDir, logLevel: zanoCoreLogLevel)
    }

    private func openOrRestoreWallet() throws {
        let walletExists = api.walletExists(path: walletPath)

        let resultJson: String?

        if walletExists {
            logger?.debug("wallet exists at path \(walletPath), opening")
            resultJson = api.openWallet(path: walletPath, password: walletPassword)
        } else {
            logger?.debug("Restoring wallet to: \(walletPath)")

            switch wallet {
            case let .bip39(words, passphrase, creationTimestamp):
                resultJson = try restoreFromBip39(words: words, passphrase: passphrase, creationTimestamp: creationTimestamp)

            case let .legacy(words, passphrase):
                resultJson = api.restoreWallet(
                    seed: words.joined(separator: " "),
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
              let result = response["result"] as? [String: Any]
        else {
            // Check for error
            if let data = json.data(using: .utf8),
               let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = response["error"] as? [String: Any],
               let message = error["message"] as? String
            {
                throw ZanoCoreError.walletRecoveryFailed(message)
            }
            throw ZanoCoreError.walletRecoveryFailed("Failed to parse wallet response")
        }

        guard let walletIdValue = result["wallet_id"] as? Int64 else {
            throw ZanoCoreError.walletRecoveryFailed("No wallet_id in response")
        }

        if case let .bip39(_, _, creationTimestamp) = wallet {
            if walletExists {
                if let stored = storedCreationTimestamp {
                    if stored != creationTimestamp {
                        _ = api.closeWallet(walletId: walletIdValue)
                        throw ZanoCoreError.restoreHeightDontMatch
                    }
                } else {
                    onFirstRestore?(creationTimestamp)
                }
            } else {
                onFirstRestore?(creationTimestamp)
            }
        }

        walletId = walletIdValue

        // Extract address from wi (wallet info)
        if let wi = result["wi"] as? [String: Any],
           let address = wi["address"] as? String
        {
            walletAddress = address
            logger?.debug("Wallet address: \(address)")

            // Parse initial balances
            if let balancesArray = wi["balances"] as? [[String: Any]] {
                parseBalancesResponse(balancesArray)
            }
        }

        wallet.clear()
        logger?.debug("Wallet opened with id: \(walletIdValue)")
    }

    private func restoreFromBip39(words: [String], passphrase: String, creationTimestamp: UInt64) throws -> String? {
        // Derive 32-byte secret from BIP39 mnemonic
        let secretDerivation = try secretDerivationFromBip39(mnemonic: words, passphrase: passphrase)

        // Build params for restore_from_derivations
        let params: [String: Any] = [
            "pass": walletPassword,
            "path": walletPath,
            "secret_derivation": secretDerivation,
            "is_auditable": false,
            "creation_timestamp": creationTimestamp,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: params, options: .sortedKeys),
              let jsonString = String(data: jsonData, encoding: .utf8)
        else {
            throw ZanoCoreError.walletRecoveryFailed("Failed to build restore params")
        }

        return api.syncCall(
            method: "restore_from_derivations",
            instanceId: 0,
            params: jsonString,
            logParams: nil
        )
    }

    private func parseBalancesResponse(_ balancesArray: [[String: Any]]) {
        var parsedAssets: [Asset] = []
        var parsedBalances: [AssetBalance] = []

        for balanceInfo in balancesArray {
            guard let assetInfo = balanceInfo["asset_info"] as? [String: Any],
                  let assetId = assetInfo["asset_id"] as? String
            else {
                continue
            }

            // Parse asset info
            let ticker = assetInfo["ticker"] as? String ?? ""
            let fullName = assetInfo["full_name"] as? String ?? ""
            let decimalPoint = assetInfo["decimal_point"] as? Int ?? 12
            let totalMaxSupply = (assetInfo["total_max_supply"] as? NSNumber)?.uint64Value ?? 0
            let currentSupply = (assetInfo["current_supply"] as? NSNumber)?.uint64Value ?? 0
            let metaInfo = assetInfo["meta_info"] as? String

            let asset = Asset(
                assetId: assetId,
                ticker: ticker,
                fullName: fullName,
                decimalPoint: decimalPoint,
                totalMaxSupply: totalMaxSupply,
                currentSupply: currentSupply,
                metaInfo: metaInfo
            )
            parsedAssets.append(asset)

            // Parse balance
            let total = (balanceInfo["total"] as? NSNumber)?.int64Value ?? 0
            let unlocked = (balanceInfo["unlocked"] as? NSNumber)?.int64Value ?? 0
            let awaitingIn = (balanceInfo["awaiting_in"] as? NSNumber)?.int64Value ?? 0
            let awaitingOut = (balanceInfo["awaiting_out"] as? NSNumber)?.int64Value ?? 0

            let balance = AssetBalance(
                assetId: assetId,
                total: total,
                unlocked: unlocked,
                awaitingIn: awaitingIn,
                awaitingOut: awaitingOut
            )
            parsedBalances.append(balance)
        }

        updateAssets(parsedAssets)
        updateBalances(parsedBalances)
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
        _ = api.invoke(walletId: wid, method: "store")
    }

    func updateBalance() {
        guard let wid = walletId else { return }

        // Skip if wallet is busy with long refresh
        if stateManager.isInLongRefresh {
            return
        }

        guard let resultJson = api.invoke(walletId: wid, method: "getbalance") else { return }

        let (result, _) = api.parseResponse(resultJson)
        guard let result else { return }

        if let balancesArray = result["balances"] as? [[String: Any]] {
            parseBalancesResponse(balancesArray)
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
            "update_provision_info": true,
        ]

        guard let resultJson = api.invoke(walletId: wid, method: "get_recent_txs_and_info", params: params) else {
            logger?.debug("Fetch transactions: no response (wallet may be busy)")
            return
        }

        let (result, error) = api.parseResponse(resultJson)

        if let error {
            logger?.debug("Fetch transactions error: \(error.code) - \(error.message)")
            return
        }

        guard let result else {
            // No result might just mean no transactions yet
            return
        }

        var fetchedTransactions: [Transaction] = []

        if let transfers = result["transfers"] as? [[String: Any]] {
            for tx in transfers {
                guard let txHash = tx["tx_hash"] as? String else { continue }

                let isIncome = tx["is_income"] as? Bool ?? false
                let fee = (tx["fee"] as? NSNumber)?.uint64Value ?? 0
                let height = (tx["height"] as? NSNumber)?.uint64Value ?? 0
                let timestamp = tx["timestamp"] as? Int ?? 0
                let comment = (tx["comment"] as? String).flatMap { $0.isEmpty ? nil : $0 }

                // Determine remote address; fall back to cached info for transactions we sent
                var remoteAddress: String?
                if let remoteAddresses = tx["remote_addresses"] as? [String], !remoteAddresses.isEmpty {
                    remoteAddress = remoteAddresses.first
                }
                if remoteAddress == nil {
                    remoteAddress = sentTransfersMap[txHash]?.address
                }

                // Track how many records this transaction contributes (used below for self-send synthesis)
                var txRecordsCreated = 0

                // Parse subtransfers for multi-asset support
                if let subtransfers = tx["subtransfers"] as? [[String: Any]], !subtransfers.isEmpty {
                    for subtransfer in subtransfers {
                        let assetId = subtransfer["asset_id"] as? String ?? ZanoAssetId
                        let amount = (subtransfer["amount"] as? NSNumber)?.uint64Value ?? 0
                        // Each subtransfer can have its own is_income flag
                        let subtransferIsIncome = subtransfer["is_income"] as? Bool ?? isIncome

                        // Skip fee subtransfer — the ZANO fee always appears as an outgoing subtransfer
                        // equal to the fee amount. We skip it since fee is tracked in the fee field.
                        // For self-sends this is the ONLY subtransfer; the sentToSelf record is
                        // synthesized below from sentTransfers.
                        if !subtransferIsIncome, assetId == ZanoAssetId, amount == fee {
                            continue
                        }

                        let subtransferType: TransactionType = subtransferIsIncome ? .incoming : .outgoing

                        // For regular outgoing native ZANO, subtract fee to get the net sent amount.
                        // For all other cases use the amount as-is.
                        let storedAmount: Int64
                        if !subtransferIsIncome, assetId == ZanoAssetId {
                            storedAmount = Int64(amount - fee)
                        } else {
                            storedAmount = Int64(amount)
                        }

                        fetchedTransactions.append(Transaction(
                            hash: txHash,
                            assetId: assetId,
                            type: subtransferType,
                            blockHeight: height,
                            amount: storedAmount,
                            fee: fee,
                            isPending: height == 0,
                            isFailed: false,
                            timestamp: timestamp,
                            note: comment,
                            recipientAddress: remoteAddress
                        ))
                        txRecordsCreated += 1
                    }
                } else {
                    let type: TransactionType = isIncome ? .incoming : .outgoing
                    let amount = (tx["amount"] as? NSNumber)?.int64Value ?? 0
                    let storedAmount: Int64 = isIncome ? abs(amount) : abs(amount) - Int64(fee)

                    fetchedTransactions.append(Transaction(
                        hash: txHash,
                        assetId: ZanoAssetId,
                        type: type,
                        blockHeight: height,
                        amount: storedAmount,
                        fee: fee,
                        isPending: height == 0,
                        isFailed: false,
                        timestamp: timestamp,
                        note: comment,
                        recipientAddress: remoteAddress
                    ))
                    txRecordsCreated += 1
                }

                // Detect self-sends where remote_addresses is absent and sentTransfers is empty
                // (e.g. after app restart). For CA self-sends the API omits remote_addresses and
                // places no CA entry in subtransfers — but employed_entries shows CA received == CA spent
                // (net = 0), which is only possible when all funds returned to the same wallet.
                if txRecordsCreated == 0, !isIncome, let employed = tx["employed_entries"] as? [String: Any] {
                    let receiveEntries = (employed["receive"] as? [[String: Any]]) ?? []
                    let spentEntries = (employed["spent"] as? [[String: Any]]) ?? []

                    var receivedByAsset: [String: [UInt64]] = [:]
                    for entry in receiveEntries {
                        let eAssetId = entry["asset_id"] as? String ?? ZanoAssetId
                        let eAmount = (entry["amount"] as? NSNumber)?.uint64Value ?? 0
                        receivedByAsset[eAssetId, default: []].append(eAmount)
                    }
                    var totalSpentByAsset: [String: UInt64] = [:]
                    for entry in spentEntries {
                        let eAssetId = entry["asset_id"] as? String ?? ZanoAssetId
                        let eAmount = (entry["amount"] as? NSNumber)?.uint64Value ?? 0
                        totalSpentByAsset[eAssetId, default: 0] += eAmount
                    }

                    var sentToSelfTxs: [Transaction] = []
                    for (assetId, amounts) in receivedByAsset {
                        let totalReceived = amounts.reduce(0, +)
                        if let totalSpent = totalSpentByAsset[assetId], totalReceived > 0,
                           (assetId == ZanoAssetId) ? totalReceived + fee == totalSpent : totalReceived == totalSpent {
                            let sentAmount: UInt64
                            if let sentInfo = sentTransfersMap[txHash], sentInfo.assetId == assetId {
                                sentAmount = sentInfo.amount
                            } else {
                                // Heuristic: minimum individual output is the likely sent amount
                                sentAmount = amounts.first ?? totalReceived
                            }
                            sentToSelfTxs.append(Transaction(
                                hash: txHash,
                                assetId: assetId,
                                type: .sentToSelf,
                                blockHeight: height,
                                amount: Int64(sentAmount),
                                fee: fee,
                                isPending: height == 0,
                                isFailed: false,
                                timestamp: timestamp,
                                note: comment,
                                recipientAddress: walletAddress.isEmpty ? nil : walletAddress
                            ))
                        }
                    }
                    if !sentToSelfTxs.isEmpty {
                        let txToAdd = sentToSelfTxs.first(where: { $0.assetId != ZanoAssetId }) ?? sentToSelfTxs.first!
                        fetchedTransactions.append(txToAdd)
                    }
                }
            }
        }

        updateTransactions(fetchedTransactions.sorted { $0.timestamp > $1.timestamp })
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

    func setConnectingState(waiting: Bool) {
        stateManager.state = .connecting(waiting: waiting)
    }

    func start() throws {
        try initializeLibrary()
        try openOrRestoreWallet()
        stateManager.validateReachable()
        startWalletServices()
    }

    func stop() {
        stopWalletServices()

        guard let wid = walletId else { return }
        _ = api.closeWallet(walletId: wid)
        walletId = nil
    }

    func refresh() {
        updateBalance()
        fetchTransactions()
    }

    // MARK: - Send Transaction

    func send(to address: String, assetId: String = ZanoAssetId, amount: UInt64, fee: UInt64, mixin: Int = 10, comment: String?) throws -> SendResult {
        guard let wid = walletId else {
            throw ZanoCoreError.walletNotInitialized
        }

        // Build destination with asset_id
        var destination: [String: Any] = [
            "address": address,
            "amount": amount,
        ]

        // Only include asset_id if not native ZANO
        if assetId != ZanoAssetId {
            destination["asset_id"] = assetId
        }

        // Build the transfer params
        var transferParams: [String: Any] = [
            "destinations": [destination],
            "fee": fee,
            "mixin": mixin,
        ]

        // Add comment if provided
        if let comment, !comment.isEmpty {
            transferParams["comment"] = comment
        }

        guard let resultJson = api.invoke(walletId: wid, method: "transfer", params: transferParams) else {
            throw ZanoCoreError.transactionSendFailed("No response from wallet")
        }

        let (result, error) = api.parseResponse(resultJson)

        if let error {
            if let matchedError = ZanoCoreError.match(error.message) {
                throw matchedError
            }
            throw ZanoCoreError.transactionSendFailed(error.message)
        }

        guard let result, let txHash = result["tx_hash"] as? String else {
            throw ZanoCoreError.transactionSendFailed("No transaction hash in response")
        }

        let sendResult = SendResult(txHash: txHash, assetId: assetId, amount: amount, address: address)
        sentTransfersMap[txHash] = sendResult

        // Refresh to update balance and transactions
        walletQueue.async { [weak self] in
            self?.refresh()
        }

        return sendResult
    }

    // MARK: - Balance Helpers

    func getBalance(forAssetId assetId: String) -> AssetBalance? {
        balances.first { $0.assetId == assetId }
    }

    func getNativeBalance() -> AssetBalance? {
        getBalance(forAssetId: ZanoAssetId)
    }

    // MARK: - Static Methods

    static func isValid(address: String) -> Bool {
        let api = ZanoWalletAPI(logger: nil)
        return api.isValidAddress(address)
    }

    // MARK: - Internal Types

    struct SendResult {
        let txHash: String
        let assetId: String
        let amount: UInt64
        let address: String
    }

    struct Asset: Equatable {
        let assetId: String
        let ticker: String
        let fullName: String
        let decimalPoint: Int
        let totalMaxSupply: UInt64
        let currentSupply: UInt64
        let metaInfo: String?
    }

    struct AssetBalance: Equatable {
        let assetId: String
        let total: Int64
        let unlocked: Int64
        let awaitingIn: Int64
        let awaitingOut: Int64

        static func == (lhs: AssetBalance, rhs: AssetBalance) -> Bool {
            lhs.assetId == rhs.assetId &&
                lhs.total == rhs.total &&
                lhs.unlocked == rhs.unlocked &&
                lhs.awaitingIn == rhs.awaitingIn &&
                lhs.awaitingOut == rhs.awaitingOut
        }
    }

    struct Transaction: Equatable {
        let hash: String
        let assetId: String
        let type: TransactionType
        let blockHeight: UInt64
        let amount: Int64
        let fee: UInt64
        let isPending: Bool
        let isFailed: Bool
        let timestamp: Int
        let note: String?
        let recipientAddress: String?

        /// Unique identifier for the transaction (hash + assetId)
        var uid: String {
            "\(hash)_\(assetId)"
        }

        static func == (lhs: Transaction, rhs: Transaction) -> Bool {
            lhs.hash == rhs.hash &&
                lhs.assetId == rhs.assetId &&
                lhs.type == rhs.type &&
                lhs.blockHeight == rhs.blockHeight &&
                lhs.amount == rhs.amount &&
                lhs.fee == rhs.fee &&
                lhs.isPending == rhs.isPending &&
                lhs.isFailed == rhs.isFailed &&
                lhs.timestamp == rhs.timestamp &&
                lhs.note == rhs.note &&
                lhs.recipientAddress == rhs.recipientAddress
        }
    }
}

protocol ZanoCoreDelegate: AnyObject {
    func assetsDidChange(assets: [ZanoCore.Asset])
    func balancesDidChange(balances: [ZanoCore.AssetBalance])
    func transactionsDidChange(transactions: [ZanoCore.Transaction])
    func walletStateDidChange(state: WalletState)
}

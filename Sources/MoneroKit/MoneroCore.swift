import CMonero
import Combine
import Foundation
import HsToolKit

class MoneroCore {
    weak var delegate: MoneroCoreDelegate?

    // Serial: delegate callbacks must never overlap - downstream Rx subjects are not
    // built for concurrent emission, and ordering must be predictable.
    let globalEventQueue = DispatchQueue(label: "io.horizontalsystems.monero_kit.event_queue", qos: .utility)
    private let walletQueue = DispatchQueue(label: "io.horizontalsystems.monero_kit.wallet_queue", qos: .utility)

    private var wallet: MoneroWallet
    private var stateManager: SyncStateManager
    private var walletListener: WalletListener
    private var networkType: NetworkType = .mainnet
    private var walletManagerPointer: UnsafeMutableRawPointer?
    private let servicesStateLock = NSLock()
    private var servicesStopped = false
    private var walletPointer: UnsafeMutableRawPointer?
    private var cWalletPath: UnsafeMutablePointer<CChar>?
    private var cWalletPassword: UnsafeMutablePointer<CChar>?
    private let logger: Logger?
    private let moneroCoreLogLevel: Int32? // 0..4
    private var restoreHeight: UInt64 = 0
    var account: UInt32
    var node: Node

    private var transactions: [Transaction] = [] {
        didSet {
            let transactions = transactions
            globalEventQueue.async { [weak self] in
                self?.delegate?.transactionsDidChange(transactions: transactions)
            }
        }
    }

    private var accounts: [AccountInfo] = [] {
        didSet {
            let accounts = accounts
            globalEventQueue.async { [weak self] in
                if oldValue != accounts {
                    self?.delegate?.accountsDidChange(accounts: accounts)
                }
            }
        }
    }

    private var balance: Balance = .init(all: 0, unlocked: 0) {
        didSet {
            let balance = balance
            globalEventQueue.async { [weak self] in
                if oldValue != balance {
                    self?.delegate?.balanceDidChange(balance: balance)
                }
            }
        }
    }

    var state: WalletState {
        stateManager.state
    }

    var blockHeights: (UInt64, UInt64)? {
        stateManager.blockHeights
    }

    init(wallet: MoneroWallet, account: UInt32, walletPath: String, walletPassword: String, node: Node, restoreHeight: UInt64, networkType: NetworkType, reachabilityManager: ReachabilityManager, logger: Logger?, moneroCoreLogLevel: Int32?) {
        self.wallet = wallet
        self.account = account
        cWalletPath = strdup((walletPath as NSString).utf8String)
        cWalletPassword = strdup((walletPassword as NSString).utf8String)
        self.node = node
        self.restoreHeight = restoreHeight
        self.networkType = networkType
        self.logger = logger
        self.moneroCoreLogLevel = moneroCoreLogLevel
        stateManager = SyncStateManager(logger: logger, restoreHeight: restoreHeight, reachabilityManager: reachabilityManager)
        walletListener = WalletListener()
        walletManagerPointer = MONERO_WalletManagerFactory_getWalletManager()

        stateManager.onSyncStateChanged = { [weak self] in
            self?.onSyncStateChanged()
        }

    }

    deinit {
        wallet.clear()

        // Free non-sensitive data
        if let ptr = cWalletPassword { free(ptr) }
        if let ptr = cWalletPath { free(ptr) }
    }

    private func startStateManager() {
        guard let walletPointer, let cWalletPassword else { return }

        stateManager.start(walletPointer: walletPointer, cWalletPassword: cWalletPassword)
    }

    private func openWallet() throws {
        if let moneroCoreLogLevel {
            MONERO_WalletManagerFactory_setLogLevel(moneroCoreLogLevel)
        }

        guard let walletManagerPointer, let cWalletPath else { return }

        let walletExists = MONERO_WalletManager_walletExists(walletManagerPointer, cWalletPath)
        var recoveredWalletPtr: UnsafeMutableRawPointer?

        if walletExists {
            recoveredWalletPtr = MONERO_WalletManager_openWallet(walletManagerPointer, cWalletPath, cWalletPassword, networkType.rawValue)
            let currentRestoreHeight = MONERO_Wallet_getRefreshFromBlockHeight(recoveredWalletPtr!)

            if currentRestoreHeight != restoreHeight {
                MONERO_WalletManager_closeWallet(walletManagerPointer, recoveredWalletPtr, false)
                throw MoneroCoreError.restoreHeightDontMatch
            }
        } else {
            switch wallet {
            case let .bip39(mnemonic, passphrase):
                let legacySeed = try legacySeedFromBip39(mnemonic: mnemonic, passphrase: passphrase)

                recoveredWalletPtr = MONERO_WalletManager_recoveryWallet(
                    walletManagerPointer,
                    cWalletPath,
                    cWalletPassword,
                    (legacySeed as NSString).utf8String,
                    networkType.rawValue,
                    restoreHeight,
                    1,
                    ""
                )

            case let .legacy(mnemonic, passphrase):
                let seed = mnemonic.joined(separator: " ").decomposedStringWithCompatibilityMapping

                recoveredWalletPtr = MONERO_WalletManager_recoveryWallet(
                    walletManagerPointer,
                    cWalletPath,
                    cWalletPassword,
                    (seed as NSString).utf8String,
                    networkType.rawValue,
                    restoreHeight,
                    1,
                    passphrase
                )

            case let .polyseed(mnemonic, passphrase):
                let seed = mnemonic.joined(separator: " ").decomposedStringWithCompatibilityMapping

                recoveredWalletPtr = MONERO_WalletManager_createWalletFromPolyseed(
                    walletManagerPointer,
                    cWalletPath,
                    cWalletPassword,
                    networkType.rawValue,
                    (seed as NSString).utf8String,
                    passphrase,
                    false,
                    restoreHeight,
                    1
                )

            case let .watch(address, viewKey):
                recoveredWalletPtr = MONERO_WalletManager_createWalletFromKeys(
                    walletManagerPointer,
                    cWalletPath,
                    cWalletPassword,
                    "",
                    networkType.rawValue,
                    restoreHeight,
                    (address as NSString).utf8String,
                    (viewKey as NSString).utf8String,
                    "",
                    1
                )
            }
        }

        guard let walletPtr = recoveredWalletPtr else {
            let errorCStr = MONERO_WalletManager_errorString(walletManagerPointer)
            let msg = stringFromCString(errorCStr) ?? "Unknown recovery error"
            logger?.error("Error recovering wallet: \(msg)")
            throw MoneroCoreError.walletRecoveryFailed(msg)
        }

        let daemonAddress = node.url.absoluteString
        let daemonLogin = node.login ?? ""
        let daemonPassword = node.password ?? ""

        logger?.debug("Initializing wallet with daemon: \(daemonAddress)")

        let cDaemonAddress = strdup((daemonAddress as NSString).utf8String)
        let cDaemonLogin = strdup((daemonLogin as NSString).utf8String)
        let cDaemonPassword = strdup((daemonPassword as NSString).utf8String)

        defer {
            free(cDaemonAddress)
            free(cDaemonLogin)
            free(cDaemonPassword)
        }

        let initSuccess = MONERO_Wallet_init(walletPtr, cDaemonAddress, 0, cDaemonLogin, cDaemonPassword, true, false, "")
        guard initSuccess else {
            let errorCStr = MONERO_Wallet_errorString(walletPtr)
            let msg = stringFromCString(errorCStr) ?? "Unknown daemon init error"
            logger?.error("Error initializing wallet with daemon: \(msg)")
            throw MoneroCoreError.daemonInitFailed(msg)
        }

        MONERO_Wallet_setTrustedDaemon(walletPtr, node.isTrusted)

        walletPointer = recoveredWalletPtr
        wallet.clear()
    }

    private func onSyncStateChanged() {
        globalEventQueue.async { [weak self] in
            guard let self else { return }
            delegate?.walletStateDidChange(state: state)
        }

        switch state {
        case .connecting, .notSynced: ()

        case .synced:
            refresh()
            stateManager.walletStored()

        case .syncing:
            if stateManager.chunkOfBlocksSynced {
                refresh()
                stateManager.walletStored()
            }

        case let .idle(daemonReachable):
            daemonReachable ? startWalletServices() : stopWalletServices()
        }
    }

    private func storeWallet(walletPointer: UnsafeMutableRawPointer) {
        _ = MONERO_Wallet_store(walletPointer, cWalletPath)
    }

    private func updateBalance(walletPointer: UnsafeMutableRawPointer, account: UInt32) {
        let allBalance = MONERO_Wallet_balance(walletPointer, account)
        let unlocked = MONERO_Wallet_unlockedBalance(walletPointer, account)
        balance = Balance(all: allBalance, unlocked: unlocked)
    }

    private func fetchSubaddresses(walletPointer: UnsafeMutableRawPointer, account: UInt32) {
        var fetchedAddresses: [SubAddress] = []
        let count = MONERO_Wallet_numSubaddresses(walletPointer, account)

        for i in 0 ..< count {
            if let address = stringFromCString(MONERO_Wallet_address(walletPointer, UInt64(account), UInt64(i))) {
                fetchedAddresses.append(.init(address: address, index: i, accountIndex: account))
            }
        }

        globalEventQueue.async { [weak self] in
            guard let self else { return }
            delegate?.subAddresssesDidChange(subAddresses: fetchedAddresses, account: account)
        }
    }

    private func updateAccounts(walletPointer: UnsafeMutableRawPointer) {
        let count = MONERO_Wallet_numSubaddressAccounts(walletPointer)
        var fetchedAccounts: [AccountInfo] = []

        for i in 0 ..< UInt32(count) {
            var label = stringFromCString(MONERO_Wallet_getSubaddressLabel(walletPointer, i, 0))
            if let _label = label, _label.isEmpty { label = nil }

            let balance = BalanceInfo(
                all: Int64(clamping: MONERO_Wallet_balance(walletPointer, i)),
                unlocked: Int64(clamping: MONERO_Wallet_unlockedBalance(walletPointer, i))
            )

            fetchedAccounts.append(AccountInfo(index: i, label: label, balance: balance))
        }

        accounts = fetchedAccounts
    }

    private func fetchTransactions(walletPointer: UnsafeMutableRawPointer) {
        let historyPtr = MONERO_Wallet_history(walletPointer)

        guard let historyPtr else { return }

        MONERO_TransactionHistory_refresh(historyPtr)

        let count = MONERO_TransactionHistory_count(historyPtr)
        var fetchedTransactions: [Transaction] = []

        for i in 0 ..< count {
            let txInfoPtr = MONERO_TransactionHistory_transaction(historyPtr, i)

            guard let txInfoPtr else { continue }

            let directionRaw = MONERO_TransactionInfo_direction(txInfoPtr)
            guard let direction = Transaction.Direction(rawValue: directionRaw) else { continue }

            let hash = stringFromCString(MONERO_TransactionInfo_hash(txInfoPtr)) ?? "N/A"

            var subaddrIndices: [Int] = []
            if let subaddrIndicesStr = stringFromCString(MONERO_TransactionInfo_subaddrIndex(txInfoPtr, " ")) {
                subaddrIndices = subaddrIndicesStr.split(separator: " ").compactMap { Int($0) }
            }

            var note: String? = stringFromCString(MONERO_Wallet_getUserNote(walletPointer, hash))
            if let _note = note, _note.isEmpty { note = nil }

            let transaction = Transaction(
                direction: direction,
                isPending: MONERO_TransactionInfo_isPending(txInfoPtr),
                isFailed: MONERO_TransactionInfo_isFailed(txInfoPtr),
                amount: MONERO_TransactionInfo_amount(txInfoPtr),
                fee: MONERO_TransactionInfo_fee(txInfoPtr),
                subaddrIndices: subaddrIndices,
                subaddrAccount: MONERO_TransactionInfo_subaddrAccount(txInfoPtr),
                blockHeight: MONERO_TransactionInfo_blockHeight(txInfoPtr),
                confirmations: MONERO_TransactionInfo_confirmations(txInfoPtr),
                hash: hash,
                timestamp: Date(timeIntervalSince1970: TimeInterval(MONERO_TransactionInfo_timestamp(txInfoPtr))),
                note: note
            )

            // All accounts' transactions are kept; scoping to the active account happens
            // at query time in storage.
            fetchedTransactions.append(transaction)
        }

        transactions = fetchedTransactions.sorted(by: { $0.timestamp > $1.timestamp })

        // Biggest number of confirmations amoung unconfirmed (less than 10 blocks) transactions
        var biggestConfirmations: UInt64 = 0
        var hasUnconfirmedTransactions = false

        for transaction in transactions {
            if transaction.confirmations >= Kit.confirmationsThreshold {
                continue
            }

            if transaction.confirmations > biggestConfirmations {
                biggestConfirmations = transaction.confirmations
                hasUnconfirmedTransactions = true
            }
        }

        if hasUnconfirmedTransactions, biggestConfirmations < Kit.confirmationsThreshold {
            let height: UInt64
            if stateManager.walletHeight < biggestConfirmations {
                height = stateManager.walletHeight
            } else {
                height = stateManager.walletHeight - biggestConfirmations
            }
            walletListener.setLockedBalanceHeight(height: height)
        }
    }

    private func startCore() throws {
        guard walletPointer == nil else { return }
        do {
            try openWallet()
        } catch {
            if let coreError = error as? MoneroCoreError, case .restoreHeightDontMatch = coreError {
                throw error
            } else {
                stateManager.state = .notSynced(error: .startError(error.localizedDescription))
            }
        }
    }

    private func stopCore() {
        let wp: UnsafeMutableRawPointer? = walletQueue.sync {
            let wp = walletPointer
            walletPointer = nil
            return wp
        }

        guard let wmp = walletManagerPointer, let wp else { return }
        // Store wallet before closing. MONERO_Wallet_store routes through
        // WalletImpl::store() which acquires LOCK_REFRESH(), ensuring the
        // C++ refresh thread has stopped before serializing. Calling
        // closeWallet with store=true would bypass this lock and race with
        // the refresh thread, crashing in wallet2::get_cache_file_data().
        _ = MONERO_Wallet_store(wp, cWalletPath)
        MONERO_WalletManager_closeWallet(wmp, wp, false)
    }

    private func startWalletServices() {
        servicesStateLock.lock()
        let stopped = servicesStopped
        servicesStateLock.unlock()

        // The teardown drain must win: a reachability flip or listener tick observed
        // mid-drain must not restart services while the wallet is about to close.
        guard !stopped, let walletPointer else { return }

        stateManager.state = .connecting(waiting: false)
        startStateManager()

        // Assigned here (not only at init) because both stop paths nil it out for teardown
        // safety - without reassignment the instant-refresh behavior would die after the
        // first background/foreground cycle.
        walletListener.onNewTransaction = { [weak self] in
            // Refresh right away so an incoming (even unconfirmed) transaction surfaces
            // immediately; the state poll alone only refreshes when the sync state changes,
            // which can be a whole block time away.
            self?.refresh()
            self?.startStateManager()
        }
        walletListener.start(walletPointer: walletPointer)
    }

    private func stopWalletServices() {
        stateManager.stop()
        walletListener.stop()
    }

    // Draining variant for the paths that go on to close or store the wallet:
    // waits until no poll/listener tick is still inside the C API. Listener first —
    // its onNewTransaction callback can restart the state manager. The reverse direction
    // (the state manager's reachability sink reaching startWalletServices and restarting
    // the already-drained listener) is closed by the servicesStopped flag. Only safe from
    // the lifecycle queue (the plain stopWalletServices is also called from the
    // reachability .idle handler, which runs on the state queue and must not sync).
    private func stopWalletServicesAndDrain() {
        servicesStateLock.lock()
        servicesStopped = true
        servicesStateLock.unlock()

        walletListener.stopAndDrain()
        stateManager.stopAndDrain()
    }

    private func allowWalletServices() {
        servicesStateLock.lock()
        servicesStopped = false
        servicesStateLock.unlock()
    }

    func start() throws {
        guard walletManagerPointer != nil else {
            logger?.error("Error: Could not get WalletManager instance.")
            return
        }

        allowWalletServices()
        stateManager.validateReachable()
        try startCore()
        startWalletServices()
    }

    func stop() {
        stopWalletServicesAndDrain()
        stopCore()
    }

    func pause() {
        stopWalletServicesAndDrain()

        walletQueue.sync { [weak self] in
            guard let self, let walletPtr = walletPointer else { return }
            MONERO_Wallet_pauseRefresh(walletPtr)
            storeWallet(walletPointer: walletPtr)
        }
    }

    func resume() {
        guard let walletPtr = walletPointer else { return }

        allowWalletServices()
        MONERO_Wallet_startRefresh(walletPtr)
        startWalletServices()
    }

    func refresh() {
        walletQueue.async { [weak self] in
            guard let self, let walletPtr = walletPointer else { return }
            let account = account
            updateBalance(walletPointer: walletPtr, account: account)
            fetchSubaddresses(walletPointer: walletPtr, account: account)
            fetchTransactions(walletPointer: walletPtr)
            updateAccounts(walletPointer: walletPtr)
            storeWallet(walletPointer: walletPtr)
        }
    }

    func setActiveAccount(_ index: UInt32) {
        account = index
        refresh()
    }

    func createAccount(label: String?) throws -> AccountInfo {
        try walletQueue.sync {
            guard let walletPtr = walletPointer else {
                throw MoneroCoreError.walletNotInitialized
            }

            MONERO_Wallet_addSubaddressAccount(walletPtr, label ?? "")
            let newIndex = UInt32(MONERO_Wallet_numSubaddressAccounts(walletPtr)) - 1
            storeWallet(walletPointer: walletPtr)
            updateAccounts(walletPointer: walletPtr)

            return AccountInfo(index: newIndex, label: label, balance: BalanceInfo(all: 0, unlocked: 0))
        }
    }

    func setAccountLabel(accountIndex: UInt32, label: String) throws {
        try walletQueue.sync {
            guard let walletPtr = walletPointer else {
                throw MoneroCoreError.walletNotInitialized
            }

            // Account labels are the (account, 0) subaddress label, persisted in the wallet cache.
            MONERO_Wallet_setSubaddressLabel(walletPtr, accountIndex, 0, label)
            storeWallet(walletPointer: walletPtr)
            updateAccounts(walletPointer: walletPtr)
        }
    }

    func setConnectingState(waiting: Bool) {
        stateManager.state = .connecting(waiting: waiting)
    }

    // On walletQueue so it cannot race stopCore, which nils the pointer under the same
    // queue before closing the wallet: callers run on the global event queue (delegate
    // callbacks generating extra addresses), which the close-path drains do not cover.
    func address(index: Int) -> String {
        walletQueue.sync {
            guard let walletPtr = walletPointer else { return "" }
            return stringFromCString(MONERO_Wallet_address(walletPtr, UInt64(account), UInt64(index))) ?? ""
        }
    }

    struct SendResult {
        let txHashes: [String]
        let txKeys: [String]
        let recipientAddress: String
    }

    // Enumerates the wallet's outputs for the current account. Coins::refresh acquires the
    // wallet2 mutex, which the background refresh thread can hold for seconds - never call
    // from the main thread.
    private func fetchOutputs(walletPointer: UnsafeMutableRawPointer, includeSpent: Bool) -> [(output: UnspentOutput, spent: Bool)] {
        guard let coinsPtr = MONERO_Wallet_coins(walletPointer) else { return [] }
        MONERO_Coins_refresh(coinsPtr)

        var outputs: [(UnspentOutput, Bool)] = []
        let count = MONERO_Coins_count(coinsPtr)

        for i in 0 ..< count {
            guard let coinPtr = MONERO_Coins_coin(coinsPtr, i) else { continue }

            let spent = MONERO_CoinsInfo_spent(coinPtr)
            guard includeSpent || !spent else { continue }

            guard MONERO_CoinsInfo_subaddrAccount(coinPtr) == account,
                  MONERO_CoinsInfo_keyImageKnown(coinPtr),
                  let keyImage = stringFromCString(MONERO_CoinsInfo_keyImage(coinPtr)), !keyImage.isEmpty
            else { continue }

            let output = UnspentOutput(
                keyImage: keyImage,
                txHash: stringFromCString(MONERO_CoinsInfo_hash(coinPtr)) ?? "",
                amount: MONERO_CoinsInfo_amount(coinPtr),
                accountIndex: MONERO_CoinsInfo_subaddrAccount(coinPtr),
                subaddressIndex: MONERO_CoinsInfo_subaddrIndex(coinPtr),
                blockHeight: MONERO_CoinsInfo_blockHeight(coinPtr),
                frozen: MONERO_CoinsInfo_frozen(coinPtr),
                unlocked: MONERO_CoinsInfo_unlocked(coinPtr)
            )

            outputs.append((output, spent))
        }

        return outputs
    }

    func unspentOutputs() throws -> [UnspentOutput] {
        try walletQueue.sync {
            guard let walletPtr = walletPointer else {
                throw MoneroCoreError.walletNotInitialized
            }

            return fetchOutputs(walletPointer: walletPtr, includeSpent: false).map(\.output)
        }
    }

    private func logOutputs(_ label: String, _ outputs: [UnspentOutput]) {
        let lines = outputs.map { output in
            "  ki=\(output.keyImage) amount=\(output.amount) tx=\(output.txHash) subaddr=\(output.accountIndex)/\(output.subaddressIndex) height=\(output.blockHeight) unlocked=\(output.unlocked) frozen=\(output.frozen)"
        }
        logger?.info("\(label) (\(outputs.count)):\n\(lines.joined(separator: "\n"))")
    }

    private func validateSelection(keyImages: [String], among outputs: [UnspentOutput], amount: SendAmount) throws {
        let outputsByKeyImage = Dictionary(uniqueKeysWithValues: outputs.map { ($0.keyImage, $0) })
        var selectedSum: UInt64 = 0

        for keyImage in keyImages {
            guard let output = outputsByKeyImage[keyImage] else {
                throw MoneroCoreError.invalidSelectedInputs("Unknown or spent output: \(keyImage)")
            }
            guard output.unlocked else {
                throw MoneroCoreError.invalidSelectedInputs("Output is still locked: \(keyImage)")
            }
            guard !output.frozen else {
                throw MoneroCoreError.invalidSelectedInputs("Output is frozen: \(keyImage)")
            }
            selectedSum += output.amount
        }

        if case .value = amount, amount.value > selectedSum {
            throw MoneroCoreError.insufficientFunds("Selected outputs hold \(selectedSum), sent amount \(amount.value)")
        }
    }

    // Serialized on walletQueue: coin/history refreshes must not run concurrently with a
    // polling refresh, and the pointer read must not race stopCore, which nils it under
    // the same queue before closing the wallet.
    func send(to address: String, amount: SendAmount, priority: SendPriority = .default, memo: String? = nil, selectedKeyImages: [String]? = nil) throws -> SendResult {
        try walletQueue.sync {
            try _send(to: address, amount: amount, priority: priority, memo: memo, selectedKeyImages: selectedKeyImages)
        }
    }

    private func _send(to address: String, amount: SendAmount, priority: SendPriority, memo: String?, selectedKeyImages: [String]?) throws -> SendResult {
        guard let walletPtr = walletPointer else {
            throw MoneroCoreError.walletNotInitialized
        }

        // The candidate set before the send, so the post-commit diff below can show which
        // outputs wallet2 actually consumed.
        let outputsBefore = fetchOutputs(walletPointer: walletPtr, includeSpent: false).map(\.output)
        logOutputs("UTXOs available before send", outputsBefore)

        var preferredInputs = ""
        var resolvedAmount = amount

        if let selectedKeyImages {
            // An explicitly empty selection must fail, not silently fall back to letting
            // the wallet pick whatever inputs it likes.
            guard !selectedKeyImages.isEmpty else {
                throw MoneroCoreError.invalidSelectedInputs("No outputs selected")
            }

            try validateSelection(keyImages: selectedKeyImages, among: outputsBefore, amount: amount)

            let selected = outputsBefore.filter { selectedKeyImages.contains($0.keyImage) }
            logOutputs("UTXOs selected for send", selected)

            // Spending the exact sum of the selection is a sweep of those outputs: the fee
            // must come out of the amount, which only create_transactions_all supports.
            let selectedSum = selected.reduce(0) { $0 + $1.amount }
            if case .value = amount, amount.value == selectedSum {
                resolvedAmount = .all
            }

            preferredInputs = selectedKeyImages.joined(separator: ",")
        }

        let cAddress = (address as NSString).utf8String
        let pendingTxPtr = MONERO_Wallet_createTransaction(walletPtr, cAddress, "", resolvedAmount.value, 0, Int32(priority.rawValue), account, preferredInputs, ",")

        guard let txPtr = pendingTxPtr else {
            let error = stringFromCString(MONERO_Wallet_errorString(walletPtr)) ?? "Unknown transaction creation error"
            throw MoneroCoreError.transactionSendFailed(error)
        }

        let status = MONERO_PendingTransaction_status(txPtr)
        guard status == 0 else {
            let error = stringFromCString(MONERO_PendingTransaction_errorString(txPtr)) ?? "Unknown pending transaction error"
            throw MoneroCoreError.match(error) ?? MoneroCoreError.transactionSendFailed(error)
        }

        guard let txIds = stringFromCString(MONERO_PendingTransaction_txid(txPtr, "|")), !txIds.isEmpty else {
            throw MoneroCoreError.transactionSendFailed("Failed to get transaction ID from pending transaction")
        }
        let txKeys = stringFromCString(MONERO_PendingTransaction_txKey(txPtr, "|")) ?? ""

        guard MONERO_PendingTransaction_commit(txPtr, "", false) else {
            let error = stringFromCString(MONERO_PendingTransaction_errorString(txPtr)) ?? "Unknown commit error"
            throw MoneroCoreError.transactionCommitFailed(error)
        }

        let txIdArray = txIds.split(separator: "|").map { String($0) }
        let txKeyArray = txKeys.split(separator: "|").map { String($0) }

        for txId in txIdArray {
            if let memo {
                let cTxId = (txId as NSString).utf8String
                MONERO_Wallet_setUserNote(walletPtr, cTxId, memo)
            }
        }

        // Which outputs the committed transaction actually consumed: candidates from before
        // the send that wallet2 now marks as spent.
        let candidateKeyImages = Set(outputsBefore.map(\.keyImage))
        let spentNow = fetchOutputs(walletPointer: walletPtr, includeSpent: true)
            .filter { $0.spent && candidateKeyImages.contains($0.output.keyImage) }
            .map(\.output)
        logOutputs("UTXOs spent by this transaction", spentNow)

        startStateManager()
        return SendResult(txHashes: txIdArray, txKeys: txKeyArray, recipientAddress: address)
    }

    func estimateFee(address: String, amount: SendAmount, priority: SendPriority = .default) throws -> UInt64 {
        try walletQueue.sync {
            try _estimateFee(address: address, amount: amount, priority: priority)
        }
    }

    private func _estimateFee(address: String, amount: SendAmount, priority: SendPriority) throws -> UInt64 {
        guard let walletPtr = walletPointer else {
            throw MoneroCoreError.walletNotInitialized
        }

        let cAddress = (address as NSString).utf8String
        let cAmount = ("\(amount.value)" as NSString).utf8String
        let fee = MONERO_Wallet_estimateTransactionFee(walletPtr, cAddress, "", cAmount, "", Int32(priority.rawValue))
        let error = stringFromCString(MONERO_Wallet_errorString(walletPtr)) ?? ""
        if !error.isEmpty, error != "No error" {
            throw MoneroCoreError.match(error) ?? MoneroCoreError.transactionEstimationFailed(error)
        }
        return fee
    }

    struct Transaction {
        public enum Direction: Int32 {
            case `in` = 0
            case out = 1
        }

        let direction: Direction
        let isPending: Bool
        let isFailed: Bool
        let amount: Int64
        let fee: UInt64
        let subaddrIndices: [Int]
        let subaddrAccount: UInt32
        let blockHeight: UInt64
        let confirmations: UInt64
        let hash: String
        let timestamp: Date
        let note: String?
    }

    struct SubAddress {
        let address: String
        let index: Int
        let accountIndex: UInt32
    }

    struct Balance: Equatable {
        // CRITICAL: Use UInt64 to prevent integer overflow on 32-bit systems
        // or for very large balances (> 2^63 piconero = ~9.2 million XMR)
        let all: UInt64
        let unlocked: UInt64

        static func == (lhs: Balance, rhs: Balance) -> Bool {
            lhs.all == rhs.all && lhs.unlocked == rhs.unlocked
        }
    }
}

extension MoneroCore {
    private static func resolveMnemonic(mnemonic: MoneroWallet) throws -> (String, String) {
        let resolvedSeedPhrase: String
        let resolvedPassphrase: String

        switch mnemonic {
        case let .bip39(mnemonic, passphrase):
            resolvedSeedPhrase = try legacySeedFromBip39(mnemonic: mnemonic, passphrase: passphrase)
            resolvedPassphrase = ""

        case let .legacy(mnemonic, passphrase):
            resolvedSeedPhrase = mnemonic.joined(separator: " ").decomposedStringWithCompatibilityMapping
            resolvedPassphrase = passphrase

        case let .polyseed(mnemonic, passphrase):
            resolvedSeedPhrase = mnemonic.joined(separator: " ").decomposedStringWithCompatibilityMapping
            resolvedPassphrase = passphrase

        case .watch:
            resolvedSeedPhrase = ""
            resolvedPassphrase = ""
        }

        return (resolvedSeedPhrase, resolvedPassphrase)
    }

    static func isValid(address: String, networkType: NetworkType) -> Bool {
        MONERO_Wallet_addressValid((address as NSString).utf8String, networkType.rawValue)
    }

    static func isValid(viewKey: String, address: String, isViewKey: Bool, networkType: NetworkType) -> Bool {
        MONERO_Wallet_keyValid((viewKey as NSString).utf8String, (address as NSString).utf8String, isViewKey, networkType.rawValue)
    }

    static func key(wallet: MoneroWallet, privateKey: Bool = false, spendKey: Bool = false) throws -> String? {
        switch wallet {
        case .bip39, .legacy, .polyseed:
            let (resolvedSeedPhrase, resolvedPassphrase) = try resolveMnemonic(mnemonic: wallet)

            guard !resolvedSeedPhrase.isEmpty else {
                return nil
            }

            let cSeed = strdup((resolvedSeedPhrase as NSString).utf8String)
            let cPassphrase = strdup((resolvedPassphrase as NSString).utf8String)
            let keyPtr = MONERO_Wallet_generateKey(cSeed, cPassphrase, privateKey, spendKey)

            return stringFromCString(keyPtr)

        case let .watch(_, viewKey):
            if privateKey, !spendKey {
                return viewKey
            } else {
                return ""
            }
        }
    }

    static func address(wallet: MoneroWallet, account: UInt32, index: UInt32, networkType: NetworkType) throws -> String {
        switch wallet {
        case .bip39, .legacy, .polyseed:
            let (resolvedSeedPhrase, resolvedPassphrase) = try resolveMnemonic(mnemonic: wallet)

            let testnet = networkType != .mainnet
            let cAddressString = MONERO_Wallet_generateAddress(resolvedSeedPhrase, resolvedPassphrase, account, index, testnet)

            return stringFromCString(cAddressString) ?? ""

        case let .watch(address, _):
            if account == 0, index == 0 {
                return address
            } else {
                return ""
            }
        }
    }
}

protocol MoneroCoreDelegate: AnyObject {
    func balanceDidChange(balance: MoneroCore.Balance)
    func transactionsDidChange(transactions: [MoneroCore.Transaction])
    func subAddresssesDidChange(subAddresses: [MoneroCore.SubAddress], account: UInt32)
    func accountsDidChange(accounts: [AccountInfo])
    func walletStateDidChange(state: WalletState)
}

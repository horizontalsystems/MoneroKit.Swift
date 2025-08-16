import CMonero
import Foundation
import HsToolKit

class MoneroCore {
    weak var delegate: MoneroCoreDelegate?

    private var mnemonic: MoneroMnemonic
    private var stateManager: SyncStateManager
    private var walletListener: WalletListener
    private var networkType: NetworkType = .mainnet
    private var walletManagerPointer: UnsafeMutableRawPointer?
    private var walletPointer: UnsafeMutableRawPointer?
    private var cWalletPath: UnsafeMutablePointer<CChar>?
    private var cWalletPassword: UnsafeMutablePointer<CChar>?
    private var node: Node
    private let logger: Logger?
    private let moneroCoreLogLevel: Int32? // 0..4
    var restoreHeight: UInt64 = 0

    private var transactions: [Transaction] = [] {
        didSet {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                delegate?.transactionsDidChange(transactions: transactions)
            }
        }
    }

    private var subAddresses: [String] = [] {
        didSet {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                delegate?.subAddresssesDidChange(subAddresses: subAddresses)
            }
        }
    }

    var state: WalletState {
        stateManager.state
    }

    var balance: BalanceInfo = .init(all: 0, unlocked: 0) {
        didSet {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if oldValue.all != balance.all || oldValue.unlocked != balance.unlocked {
                    delegate?.balanceDidChange(balanceInfo: balance)
                }
            }
        }
    }

    var receiveAddress: String {
        guard let walletPtr = walletPointer else { return "" }
        return stringFromCString(MONERO_Wallet_address(walletPtr, 0, 0)) ?? ""
    }

    init(mnemonic: MoneroMnemonic, walletPath: String, walletPassword: String, node: Node, restoreHeight: UInt64, networkType: NetworkType, logger: Logger?, moneroCoreLogLevel: Int32?) {
        self.mnemonic = mnemonic
        cWalletPath = strdup((walletPath as NSString).utf8String)
        cWalletPassword = strdup((walletPassword as NSString).utf8String)
        self.node = node
        self.restoreHeight = restoreHeight
        self.networkType = networkType
        self.logger = logger
        self.moneroCoreLogLevel = moneroCoreLogLevel
        stateManager = SyncStateManager(logger: logger)
        walletListener = WalletListener()

        walletManagerPointer = MONERO_WalletManagerFactory_getWalletManager()
    }

    deinit {
        mnemonic.clear()
        stop()

        // Free non-sensitive data
        if let ptr = cWalletPassword { free(ptr) }
        if let ptr = cWalletPath { free(ptr) }

        if let walletPointer {
            MONERO_Wallet_delete(walletPointer)
            self.walletPointer = nil
        }
    }

    func start() throws {
        guard walletManagerPointer != nil else {
            logger?.error("Error: Could not get WalletManager instance.")
            return
        }

        if walletPointer == nil {
            try openWallet()
        }

        try startBackgroundSync()
        try startWalletListener()
    }

    func stop() {
        stateManager.stop()
        walletListener.stop()
    }

    private func startBackgroundSync() throws {
        guard let walletPointer, let cWalletPassword else {
            throw MoneroCoreError.walletNotInitialized
        }

        stateManager.start(walletPointer: walletPointer, cWalletPassword: cWalletPassword) { [weak self] in
            self?.onSyncStateChanged()
        }
    }

    private func startWalletListener() throws {
        guard let walletPointer else {
            throw MoneroCoreError.walletNotInitialized
        }

        walletListener.start(walletPointer: walletPointer) { [weak self] in
            try? self?.startBackgroundSync()
        }
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
        } else {
            switch mnemonic {
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
            }
        }

        guard let walletPtr = recoveredWalletPtr else {
            let errorCStr = MONERO_WalletManager_errorString(walletManagerPointer)
            let msg = stringFromCString(errorCStr) ?? "Unknown recovery error"
            logger?.error("Error recovering wallet: \(msg)")
            return
        }

        let cDaemonAddress = strdup((node.url.absoluteString as NSString).utf8String)
        let cDaemonLogin = strdup(((node.login ?? "") as NSString).utf8String)
        let cDaemonPassword = strdup(((node.password ?? "") as NSString).utf8String)
        let initSuccess = MONERO_Wallet_init(walletPtr, cDaemonAddress, 0, cDaemonLogin, cDaemonPassword, true, false, "")
        guard initSuccess else {
            let errorCStr = MONERO_Wallet_errorString(walletPtr)
            let msg = stringFromCString(errorCStr) ?? "Unknown daemon init error"
            logger?.error("Error initializing wallet with daemon: \(msg)")
            return
        }

        MONERO_Wallet_setTrustedDaemon(walletPtr, node.isTrusted)

        walletPointer = recoveredWalletPtr
        mnemonic.clear()
        updateBalance()
    }

    private func onSyncStateChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            delegate?.walletStateDidChange(state: state)
        }

        if stateManager.state.isSynchronized {
            stateManager.stop()
        }

        if stateManager.state.isSynchronized || stateManager.chunkOfBlocksSynced {
            fetchTransactions()
            storeWallet()
            updateBalance()
            stateManager.syncCached()
        }
    }

    private func storeWallet() {
        guard let _walletPtr = walletPointer else { return }
        _ = MONERO_Wallet_store(_walletPtr, cWalletPath)
    }

    private func updateBalance() {
        guard let walletPtr = walletPointer else { return }
        let allBalance = MONERO_Wallet_balance(walletPtr, 0)
        let unlocked = MONERO_Wallet_unlockedBalance(walletPtr, 0)
        balance = BalanceInfo(all: allBalance, unlocked: unlocked)
    }

    private func fetchSubaddresses() {
        guard let walletPtr = walletPointer else { return }
        var fetchedAddresses: [String] = []
        let count = MONERO_Wallet_numSubaddresses(walletPtr, 0)

        for i in 0 ..< count {
            if let address = stringFromCString(MONERO_Wallet_address(walletPtr, 0, UInt64(i))) {
                fetchedAddresses.append(address)
            }
        }

        subAddresses = fetchedAddresses
    }

    private func fetchTransactions() {
        guard let walletPtr = walletPointer else { return }

        let historyPtr = MONERO_Wallet_history(walletPtr)
        MONERO_TransactionHistory_refresh(historyPtr)

        let count = MONERO_TransactionHistory_count(historyPtr)
        var fetchedTransactions: [Transaction] = []

        for i in 0 ..< count {
            let txInfoPtr = MONERO_TransactionHistory_transaction(historyPtr, i)

            guard let direction = Transaction.Direction(rawValue: MONERO_TransactionInfo_direction(txInfoPtr)) else { continue }
            let hash = stringFromCString(MONERO_TransactionInfo_hash(txInfoPtr)) ?? "N/A"

            var transfers: [Transfer] = []
            let transferCount = MONERO_TransactionInfo_transfers_count(txInfoPtr)

            if transferCount > 0 {
                for j in 0 ..< transferCount {
                    let transferAmount = MONERO_TransactionInfo_transfers_amount(txInfoPtr, j)
                    let address = stringFromCString(MONERO_TransactionInfo_transfers_address(txInfoPtr, j)) ?? ""
                    transfers.append(Transfer(address: address, amount: transferAmount))
                }
            }

            let transaction = Transaction(
                direction: direction,
                isPending: MONERO_TransactionInfo_isPending(txInfoPtr),
                isFailed: MONERO_TransactionInfo_isFailed(txInfoPtr),
                amount: MONERO_TransactionInfo_amount(txInfoPtr),
                fee: MONERO_TransactionInfo_fee(txInfoPtr),
                blockHeight: MONERO_TransactionInfo_blockHeight(txInfoPtr),
                confirmations: MONERO_TransactionInfo_confirmations(txInfoPtr),
                hash: hash,
                timestamp: Date(timeIntervalSince1970: TimeInterval(MONERO_TransactionInfo_timestamp(txInfoPtr))),
                transfers: transfers
            )
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

        if hasUnconfirmedTransactions, biggestConfirmations < Kit.confirmationsThreshold,
           let height = stateManager.state.walletBlockHeight
        {
            walletListener.setLockedBalanceHeight(height: height - biggestConfirmations)
        }
    }

    func send(to address: String, amount: SendAmount, priority: SendPriority = .default) throws {
        guard let walletPtr = walletPointer else {
            throw MoneroCoreError.walletNotInitialized
        }

        let cAddress = (address as NSString).utf8String
        let pendingTxPtr = MONERO_Wallet_createTransaction(walletPtr, cAddress, "", amount.value, 0, Int32(priority.rawValue), 0, "", "")

        if let txPtr = pendingTxPtr {
            let status = MONERO_PendingTransaction_status(txPtr)
            if status == 0 {
                if !MONERO_PendingTransaction_commit(txPtr, "", false) {
                    let error = stringFromCString(MONERO_PendingTransaction_errorString(txPtr)) ?? "Unknown commit error"
                    throw MoneroCoreError.transactionCommitFailed(error)
                } else {
                    try startBackgroundSync()
                }
            } else {
                let error = stringFromCString(MONERO_PendingTransaction_errorString(txPtr)) ?? "Unknown pending transaction error"
                throw MoneroCoreError.match(error) ?? MoneroCoreError.transactionSendFailed(error)
            }
        } else {
            let error = stringFromCString(MONERO_Wallet_errorString(walletPtr)) ?? "Unknown transaction creation error"
            throw MoneroCoreError.transactionSendFailed(error)
        }
    }

    func estimateFee(address: String, amount: SendAmount, priority: SendPriority = .default) throws -> UInt64 {
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
        let amount: UInt64
        let fee: UInt64
        let blockHeight: UInt64
        let confirmations: UInt64
        let hash: String
        let timestamp: Date
        var transfers: [Transfer]
    }
}

extension MoneroCore {
    static func isValid(address: String, networkType: NetworkType) -> Bool {
        MONERO_Wallet_addressValid((address as NSString).utf8String, networkType.rawValue)
    }
}

protocol MoneroCoreDelegate: AnyObject {
    func balanceDidChange(balanceInfo: BalanceInfo)
    func transactionsDidChange(transactions: [MoneroCore.Transaction])
    func subAddresssesDidChange(subAddresses: [String])
    func walletStateDidChange(state: WalletState)
}

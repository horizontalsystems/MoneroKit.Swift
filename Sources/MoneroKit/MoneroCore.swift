import CMonero
import Foundation

public enum WalletStatus {
    case unknown, ok, error(Error?), critical(Error?)

    init?(_ status: Int32, error: String?) {
        switch status {
        case 0:
            self = .ok
        case 1:
            self = .error(MoneroCoreError.walletStatusError(error))
        case 2:
            self = .critical(MoneroCoreError.walletStatusError(error))
        default:
            return nil
        }
    }
}

public enum SendPriority: Int, CaseIterable {
    case `default`, low, medium, high, last
}

class MoneroCore {
    static let storeBlocksCount: UInt64 = 2000

    weak var delegate: MoneroCoreDelegate?

    private var walletManagerPointer: UnsafeMutableRawPointer?
    private var walletPointer: UnsafeMutableRawPointer?
    private var refreshTimer: Timer?
    private var isRefreshing = false
    private var lastStoredBlockHeight: UInt64 = 0
    private let refreshQueue = DispatchQueue(label: "monero.kit.refresh-queue", qos: .userInitiated)

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

    private var mnemonic: MoneroMnemonic
    private var restoreHeight: UInt64 = 0
    private var networkType: NetworkType = .mainnet
    private var cWalletPath: UnsafeMutablePointer<CChar>?
    private var cWalletPassword: UnsafeMutablePointer<CChar>?
    private var cDaemonAddress: UnsafeMutablePointer<CChar>?

    var daemonHeight: UInt64?
    var walletBlockHeight: UInt64? {
        didSet {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                delegate?.lastBlockHeightDidChange(height: walletBlockHeight ?? 0)
            }
        }
    }

    var walletStatus: WalletStatus = .unknown {
        didSet {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch (oldValue, walletStatus) {
                case (.unknown, .unknown), (.ok, .ok), (.error, .error), (.critical, .critical): ()
                default:
                    delegate?.walletStatusDidChange(status: walletStatus)
                }
            }
        }
    }

    var isSynchronized: Bool = false {
        didSet {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if oldValue != isSynchronized {
                    delegate?.syncStateDidChange(isSynchronized: isSynchronized)
                }
            }
        }
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

    enum BackgroundSyncType: Int32 {
        case none = 0
        case `default` = 1
        case customPassword = 2
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

    init(mnemonic: MoneroMnemonic, walletPath: String, walletPassword: String, daemonAddress: String, restoreHeight: UInt64, networkType: NetworkType) {
        self.mnemonic = mnemonic
        cWalletPath = strdup((walletPath as NSString).utf8String)
        cWalletPassword = strdup((walletPassword as NSString).utf8String)
        cDaemonAddress = strdup((daemonAddress as NSString).utf8String)
        self.restoreHeight = restoreHeight
        self.networkType = networkType

        walletManagerPointer = MONERO_WalletManagerFactory_getWalletManager()
    }

    deinit {
        mnemonic.clear()
        stop()

        // Free non-sensitive data
        if let ptr = cWalletPassword { free(ptr) }
        if let ptr = cWalletPath { free(ptr) }
        if let ptr = cDaemonAddress { free(ptr) }
    }

    func close() {
        if let walletPtr = walletPointer {
            MONERO_WalletManager_closeWallet(walletManagerPointer, walletPtr, false)
            walletPointer = nil
        }
    }

    func start() throws {
        guard walletManagerPointer != nil else {
            print("Error: Could not get WalletManager instance.")
            return
        }

        if walletPointer == nil {
            try openWallet()
        }

        startBackgroundSync()
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil

        if let walletPtr = walletPointer {
            let stopped = MONERO_Wallet_stopBackgroundSync(walletPtr, cWalletPassword)
            if !stopped {
                let errorCStr = MONERO_Wallet_errorString(walletPtr)
                let msg = stringFromCString(errorCStr) ?? "Setup background sync error"
                print("Error setup Background sync: \(msg)")
                return
            }
        }
    }

    private func openWallet() throws {
        MONERO_WalletManagerFactory_setLogLevel(4)

        guard let walletManagerPointer, let cWalletPath else { return }

        let walletExists = MONERO_WalletManager_walletExists(walletManagerPointer, cWalletPath)
        var recoveredWalletPtr: UnsafeMutableRawPointer?

        if walletExists {
            recoveredWalletPtr = MONERO_WalletManager_openWallet(walletManagerPointer, cWalletPath, cWalletPassword, networkType.rawValue)
        } else {
            switch mnemonic {
            case let .bip39(mnemonic, passphrase):
                let legacySeed = try legacySeedFromBip39(mnemonic: mnemonic)

                recoveredWalletPtr = MONERO_WalletManager_recoveryWallet(
                    walletManagerPointer,
                    cWalletPath,
                    cWalletPassword,
                    (legacySeed as NSString).utf8String,
                    networkType.rawValue,
                    restoreHeight,
                    1,
                    passphrase
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

        walletPointer = recoveredWalletPtr
        mnemonic.clear()

        guard let walletPtr = recoveredWalletPtr else {
            let errorCStr = MONERO_WalletManager_errorString(walletManagerPointer)
            let msg = stringFromCString(errorCStr) ?? "Unknown recovery error"
            print("Error recovering wallet: \(msg)")
            return
        }

        let initSuccess = MONERO_Wallet_init(walletPtr, cDaemonAddress, 0, "", "", false, false, "")

        _ = MONERO_Wallet_store(walletPtr, cWalletPath)

        guard initSuccess else {
            let errorCStr = MONERO_Wallet_errorString(walletPtr)
            let msg = stringFromCString(errorCStr) ?? "Unknown daemon init error"
            print("Error initializing wallet with daemon: \(msg)")
            return
        }

        MONERO_Wallet_setTrustedDaemon(walletPtr, true)
    }

    private func startBackgroundSync() {
        guard let walletPointer else { return }

        let backgroundSyncSetupSuccess = MONERO_Wallet_setupBackgroundSync(walletPointer, BackgroundSyncType.customPassword.rawValue, cWalletPassword, "")

        if !backgroundSyncSetupSuccess {
            let errorCStr = MONERO_Wallet_errorString(walletPointer)
            let msg = stringFromCString(errorCStr) ?? "Setup background sync error"
            print("Error setup Background sync: \(msg)")
            return
        }

        let startedBackgroundSync = MONERO_Wallet_startBackgroundSync(walletPointer)
        if !startedBackgroundSync {
            let errorCStr = MONERO_Wallet_errorString(walletPointer)
            let msg = stringFromCString(errorCStr) ?? "Start background sync error"
            print("Error start Background sync: \(msg)")
            return
        }

        MONERO_Wallet_startRefresh(walletPointer)

        startRefreshTimer()
    }

    private func startRefreshTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            refreshTimer?.invalidate()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                self?.refreshQueue.async { [weak self] in
                    guard let self else { return }
                    guard !isRefreshing else {
                        return
                    }

                    isRefreshing = true
                    checkWalletStatusAndRefresh()
                    isRefreshing = false
                }
            }
        }
    }

    private func checkWalletStatusAndRefresh() {
        guard let walletPtr = walletPointer else { return }

        let newWalletStatus = MONERO_Wallet_status(walletPtr)
        if newWalletStatus != 0 {
            let errorCStr = MONERO_Wallet_errorString(walletPtr)
            let errorStr = stringFromCString(errorCStr)
            print("Wallet is in error state (\(newWalletStatus)): \(errorStr ?? "Unknown wallet error").")
            walletStatus = WalletStatus(newWalletStatus, error: errorStr) ?? .unknown
            return
        }

        let newDaemonHeight = MONERO_Wallet_daemonBlockChainHeight(walletPtr)
        let newWalletHeight = MONERO_Wallet_blockChainHeight(walletPtr)
        let newIsSynchronized = MONERO_Wallet_synchronized(walletPtr)
        daemonHeight = newDaemonHeight
        walletBlockHeight = newWalletHeight
        isSynchronized = newIsSynchronized

        if newIsSynchronized {
            stop()
            fetchSubaddresses()
            fetchTransactions()
        }

        if newIsSynchronized || (
            lastStoredBlockHeight <= newWalletHeight && newWalletHeight - lastStoredBlockHeight >= Self.storeBlocksCount
        ) {
            storeWallet()
            updateBalance()
            lastStoredBlockHeight = newWalletHeight
        }

        walletStatus = .ok
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

    public func fetchSubaddresses() {
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
    }

    func send(to address: String, amount: Int, priority: SendPriority = .default) throws {
        guard let walletPtr = walletPointer else {
            throw MoneroCoreError.walletNotInitialized
        }

        let cAddress = (address as NSString).utf8String
        let pendingTxPtr = MONERO_Wallet_createTransaction(walletPtr, cAddress, "", UInt64(amount), 0, Int32(priority.rawValue), 0, "", "")

        if let txPtr = pendingTxPtr {
            let status = MONERO_PendingTransaction_status(txPtr)
            if status == 0 {
                if !MONERO_PendingTransaction_commit(txPtr, "", false) {
                    let error = stringFromCString(MONERO_PendingTransaction_errorString(txPtr)) ?? "Unknown commit error"
                    throw MoneroCoreError.commitFailed(error)
                }
            } else {
                let error = stringFromCString(MONERO_PendingTransaction_errorString(txPtr)) ?? "Unknown pending transaction error"
                throw MoneroCoreError.creationFailed(error)
            }
        } else {
            let error = stringFromCString(MONERO_Wallet_errorString(walletPtr)) ?? "Unknown transaction creation error"
            throw MoneroCoreError.creationFailed(error)
        }
    }

    func estimateFee(amount: Int, address: String, priority: SendPriority = .default) throws -> UInt64 {
        guard let walletPtr = walletPointer else {
            return 0
        }

        let cAddress = (address as NSString).utf8String
        let pendingTxPtr = MONERO_Wallet_createTransaction(walletPtr, cAddress, "", UInt64(amount), 0, Int32(priority.rawValue), 0, "", "")

        if let txPtr = pendingTxPtr {
            let status = MONERO_PendingTransaction_status(txPtr)
            if status == 0 {
                return MONERO_PendingTransaction_fee(txPtr)
            } else {
                let error = stringFromCString(MONERO_PendingTransaction_errorString(txPtr)) ?? "Unknown pending transaction error"
                throw MoneroCoreError.estimationFailed(error)
            }
        }

        return 0
    }

    var receiveAddress: String {
        guard let walletPtr = walletPointer else { return "" }
        return stringFromCString(MONERO_Wallet_address(walletPtr, 0, 0)) ?? ""
    }
}

extension MoneroCore {
    static func isValid(address: String, networkType: NetworkType) -> Bool {
        MONERO_Wallet_addressValid((address as NSString).utf8String, networkType.rawValue)
    }
}

public enum MoneroCoreError: Error {
    case walletNotInitialized
    case estimationFailed(String)
    case creationFailed(String)
    case commitFailed(String)
    case walletStatusError(String?)
}

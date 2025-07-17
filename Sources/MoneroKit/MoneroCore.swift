import CMonero
import Foundation

class MoneroCore {
    weak var delegate: MoneroKitDelegate?

    private var walletManagerPointer: UnsafeMutableRawPointer?
    private var walletPointer: UnsafeMutableRawPointer?
    private var walletListenerPointer: UnsafeMutableRawPointer?
    private var refreshTimer: Timer?

    private var walletHeight: UInt64 = 0
    private var daemonHeight: UInt64 = 0
    private var walletStatus: Int32 = -1
    private var isSynchronized: Bool = false {
        didSet {
            if oldValue != isSynchronized {
                delegate?.syncStateDidChange(isSynchronized: isSynchronized)
            }
        }
    }

    private var balance: BalanceInfo = .init(spendable: 0, unspendable: 0) {
        didSet {
            if oldValue.spendable != balance.spendable || oldValue.unspendable != balance.unspendable {
                delegate?.balanceDidChange(balance: balance)
            }
        }
    }

    private var transactions: [TransactionInfo] = [] {
        didSet {
            delegate?.transactionsDidChange(transactions: transactions)
        }
    }

    private var mnemonic: MoneroMnemonic
    private var restoreHeight: UInt64 = 0
    private var networkType: NetworkType = .mainnet
    private var cWalletPath: UnsafeMutablePointer<CChar>?
    private var cWalletPassword: UnsafeMutablePointer<CChar>?
    private var cDaemonAddress: UnsafeMutablePointer<CChar>?

    enum BackgroundSyncType: Int32 {
        case none = 0
        case `default` = 1
        case customPassword = 2
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
        stop()

        // Free non-sensitive data
        if let ptr = cWalletPassword { free(ptr) }
        if let ptr = cWalletPath { free(ptr) }
        if let ptr = cDaemonAddress { free(ptr) }
    }

    func start() throws {
        guard walletManagerPointer != nil else {
            print("Error: Could not get WalletManager instance.")
            return
        }

        MONERO_WalletManagerFactory_setLogLevel(4)

        try openWallet()
    }

    func stop() {
        if let walletPtr = walletPointer {
            MONERO_WalletManager_closeWallet(walletManagerPointer, walletPtr, false)
            walletPointer = nil
        }
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func openWallet() throws {
        guard let walletManagerPointer, let cWalletPath else { return }

        let walletExists = MONERO_WalletManager_walletExists(walletManagerPointer, cWalletPath)
        var recoveredWalletPtr: UnsafeMutableRawPointer?

        if walletExists {
            recoveredWalletPtr = MONERO_WalletManager_openWallet(walletManagerPointer, cWalletPath, cWalletPassword, networkType.rawValue)
        } else {
            switch mnemonic {
                case .bip39(let mnemonic, let passphrase):
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

                case .legacy(let mnemonic, let passphrase):
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

                case .polyseed(let mnemonic, let passphrase):
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

        let backgroundSyncSetupSuccess = MONERO_Wallet_setupBackgroundSync(walletPtr, BackgroundSyncType.customPassword.rawValue, cWalletPassword, "")
        print("Wallet path is: \(String(cString: cWalletPath))")
        print("Wallet password is: \(cWalletPassword.map { String(cString: $0) } ?? "no password")")

        if !backgroundSyncSetupSuccess {
            let errorCStr = MONERO_Wallet_errorString(walletPtr)
            let msg = stringFromCString(errorCStr) ?? "Setup background sync error"
            print("Error setup Background sync: \(msg)")
            return
        }

        let startedBackgroundSync = MONERO_Wallet_startBackgroundSync(walletPtr)
        if !startedBackgroundSync {
            let errorCStr = MONERO_Wallet_errorString(walletPtr)
            let msg = stringFromCString(errorCStr) ?? "Start background sync error"
            print("Error start Background sync: \(msg)")
            return
        }

        walletListenerPointer = MONERO_cw_getWalletListener(walletPtr)
        MONERO_Wallet_startRefresh(walletPtr)

        startRefreshTimer()
    }

    private func startRefreshTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            refreshTimer?.invalidate()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.checkWalletStatusAndRefresh()
            }
        }
    }

    private func checkWalletStatusAndRefresh() {
        guard let walletPtr = walletPointer else { return }

        let newWalletHeight = MONERO_Wallet_blockChainHeight(walletPtr)
        let newDaemonHeight = MONERO_Wallet_daemonBlockChainHeight(walletPtr)
        let newWalletStatus = MONERO_Wallet_status(walletPtr)
        let newIsSynchronized = MONERO_Wallet_synchronized(walletPtr)
        let spendable = MONERO_Wallet_balance(walletPtr, 0)
        let unspendable = MONERO_Wallet_unlockedBalance(walletPtr, 0)

        walletHeight = newWalletHeight
        daemonHeight = newDaemonHeight
        walletStatus = newWalletStatus
        isSynchronized = newIsSynchronized
        balance = BalanceInfo(spendable: spendable, unspendable: unspendable)

        delegate?.lastBlockHeightDidChange(height: newWalletHeight)

        if let listenerPtr = walletListenerPointer, MONERO_cw_WalletListener_isNeedToRefresh(listenerPtr) {
            MONERO_Wallet_refresh(walletPtr)
            MONERO_cw_WalletListener_resetNeedToRefresh(listenerPtr)
        }

        if newWalletStatus != 0 {
            let errorCStr = MONERO_Wallet_errorString(walletPtr)
            print("Wallet is in error state (\(newWalletStatus)): \(stringFromCString(errorCStr) ?? "Unknown wallet error").")
        } else if newIsSynchronized {
            _ = MONERO_Wallet_store(walletPtr, cWalletPath)
            let stopped = MONERO_Wallet_stopBackgroundSync(walletPtr, cWalletPassword)
            if !stopped {
                let errorCStr = MONERO_Wallet_errorString(walletPtr)
                let msg = stringFromCString(errorCStr) ?? "Setup background sync error"
                print("Error setup Background sync: \(msg)")
                return
            }
            fetchTransactions()
        }
    }

    func fetchTransactions() {
        guard let walletPtr = walletPointer else { return }

        let historyPtr = MONERO_Wallet_history(walletPtr)
        MONERO_TransactionHistory_refresh(historyPtr)

        let count = MONERO_TransactionHistory_count(historyPtr)
        var fetchedTransactions: [TransactionInfo] = []

        for i in 0 ..< count {
            let txInfoPtr = MONERO_TransactionHistory_transaction(historyPtr, i)

            guard let direction = TransactionInfo.Direction(rawValue: MONERO_TransactionInfo_direction(txInfoPtr)) else { continue }
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

            let transaction = TransactionInfo(
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

    func send(to address: String, amount: Double) throws {
        guard let walletPtr = walletPointer else {
            throw SendError.walletNotInitialized
        }

        let amountValue = amount * 1_000_000_000_000
        let cAddress = (address as NSString).utf8String

        let pendingTxPtr = MONERO_Wallet_createTransaction(walletPtr, cAddress, "", UInt64(amountValue), 0, 0, 0, "", "")

        if let txPtr = pendingTxPtr {
            let status = MONERO_PendingTransaction_status(txPtr)
            if status == 0 {
                if !MONERO_PendingTransaction_commit(txPtr, "", false) {
                    let error = stringFromCString(MONERO_PendingTransaction_errorString(txPtr)) ?? "Unknown commit error"
                    throw SendError.commitFailed(error)
                }
            } else {
                let error = stringFromCString(MONERO_PendingTransaction_errorString(txPtr)) ?? "Unknown pending transaction error"
                throw SendError.creationFailed(error)
            }
        } else {
            let error = stringFromCString(MONERO_Wallet_errorString(walletPtr)) ?? "Unknown transaction creation error"
            throw SendError.creationFailed(error)
        }
    }

    func estimateFee(amount: Double) -> UInt64 {
        guard let walletPtr = walletPointer else {
            return 0
        }

        let pendingTxPtr = MONERO_Wallet_createTransaction(walletPtr, "", "", UInt64(amount * 1_000_000_000_000), 0, 0, 0, "", "")

        if let txPtr = pendingTxPtr {
            let status = MONERO_PendingTransaction_status(txPtr)
            if status == 0 {
                return MONERO_PendingTransaction_fee(txPtr)
            }
        }

        return 0
    }

    var receiveAddress: String {
        guard let walletPtr = walletPointer else { return "" }
        return stringFromCString(MONERO_Wallet_address(walletPtr, 0, 0)) ?? ""
    }

    enum SendError: Error {
        case walletNotInitialized
        case creationFailed(String)
        case commitFailed(String)
    }
}

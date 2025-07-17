import Foundation

public class MoneroKit {
    private let moneroCore: MoneroCore

    public weak var delegate: MoneroKitDelegate? {
        didSet {
            moneroCore.delegate = delegate
        }
    }

    public init(mnemonic: MoneroMnemonic, restoreHeight: UInt64 = 0, walletId: String, daemonAddress: String, networkType: NetworkType = .mainnet) throws {
        do {
            _ = try FileManager.default.createDirectory(atPath: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("monero_wallets").path, withIntermediateDirectories: true)
        } catch {
            throw MoneroKitError.invalidWalletId
        }

        let walletPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("monero_wallets/\(walletId)").path

        moneroCore = MoneroCore(
            mnemonic: mnemonic,
            walletPath: walletPath,
            walletPassword: walletId,
            daemonAddress: daemonAddress,
            restoreHeight: restoreHeight,
            networkType: networkType
        )
    }

    public func start() {
        try? moneroCore.start()
    }

    public func stop() {
        moneroCore.stop()
    }

    public var balance: BalanceInfo {
        // This will be updated via delegate. This is just for initial state.
        BalanceInfo(spendable: 0, unspendable: 0)
    }

    public var transactions: [TransactionInfo] {
        // This will be updated via delegate. This is just for initial state.
        []
    }

    public func send(to address: String, amount: Double) throws {
        try moneroCore.send(to: address, amount: amount)
    }

    public func estimateFee(amount: Double) -> UInt64 {
        moneroCore.estimateFee(amount: amount)
    }

    public var receiveAddress: String {
        moneroCore.receiveAddress
    }
}

public enum MoneroKitError: Error {
    case invalidWalletId
    case invalidSeed
}

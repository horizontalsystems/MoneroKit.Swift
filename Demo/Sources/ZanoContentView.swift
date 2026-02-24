import HsToolKit
import SwiftUI
import ZanoKit

struct ZanoContentView: View {
    @Binding var zanoKit: ZanoKit.Kit?
    @ObservedObject var walletState: Zano_WalletState

    @State private var mnemonicSeed: String = "frost pupil then system satoshi receive inhale basic retreat voice rapid misery"
    @State private var passphrase: String = ""
    @State private var walletId: String = "Zano1"
    @State private var daemonAddress: String = "http://37.27.100.59:10500"
    @State private var mnemonicType: String = "BIP39"
    @State private var creationTimestamp: String = "1771398900"
    @State private var errorMessage: String?
    @State private var showError: Bool = false

    var body: some View {
        NavigationView {
            VStack {
                if !walletState.isConnected {
                    ZanoWalletSetupView(
                        mnemonicSeed: $mnemonicSeed,
                        walletId: $walletId,
                        daemonAddress: $daemonAddress,
                        mnemonicType: $mnemonicType,
                        passphrase: $passphrase,
                        creationTimestamp: $creationTimestamp,
                        connectAction: connectToWallet
                    )
                } else {
                    ZanoWalletDashboardView(zanoKit: $zanoKit, walletState: walletState)
                }
            }
            .padding()
            .navigationTitle("Zano Wallet")
            .alert("Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Unknown error")
            }
        }
    }

    private func connectToWallet() {
        guard let nodeUrl = URL(string: daemonAddress) else {
            errorMessage = "Invalid daemon URL"
            showError = true
            return
        }
        let seed = mnemonicSeed.components(separatedBy: " ")

        let wallet: ZanoWallet
        switch mnemonicType {
        case "BIP39":
            let timestamp = UInt64(creationTimestamp) ?? 0
            wallet = .bip39(seed: seed, passphrase: passphrase, creationTimestamp: timestamp)
        case "Legacy (26 words)":
            wallet = .legacy(seed: seed, passphrase: passphrase)
        default:
            errorMessage = "Invalid mnemonic type"
            showError = true
            return
        }

        do {
            let kit = try Kit(
                wallet: wallet,
                walletId: walletId,
                daemonAddress: nodeUrl.absoluteString,
                networkType: .mainnet,
                reachabilityManager: ReachabilityManager(),
                logger: Logger(minLogLevel: .verbose),
                zanoCoreLogLevel: 1
            )
            kit.delegate = walletState
            kit.start()

            zanoKit = kit
            walletState.isConnected = true
        } catch {
            errorMessage = "Failed to create wallet: \(error.localizedDescription)"
            showError = true
        }
    }
}

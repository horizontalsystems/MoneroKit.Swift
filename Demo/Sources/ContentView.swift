import MoneroKit
import SwiftUI

struct ContentView: View {
    @Binding var moneroKit: MoneroKit?
    @ObservedObject var walletState: WalletState

    @State private var mnemonicSeed: String = ""
    @State private var walletId: String = "wallet1"
    @State private var daemonAddress: String = "xmr-node.cakewallet.com:18081"
    @State private var restoreHeight: String = "3437500"

    var body: some View {
        NavigationView {
            VStack {
                if !walletState.isConnected {
                    WalletSetupView(
                        mnemonicSeed: $mnemonicSeed,
                        walletId: $walletId,
                        daemonAddress: $daemonAddress,
                        restoreHeight: $restoreHeight,
                        connectAction: connectToWallet
                    )
                } else {
                    WalletDashboardView(moneroKit: $moneroKit, walletState: walletState)
                }
            }
            .padding()
            .navigationTitle("Monero Wallet")
        }
    }

    private func connectToWallet() {
        guard let kit = try? MoneroKit(
            mnemonic: .bip39(seed: mnemonicSeed.components(separatedBy: " "), passphrase: ""),
            restoreHeight: UInt64(restoreHeight) ?? 0,
            walletId: walletId,
            daemonAddress: daemonAddress
        ) else {
            return
        }

        kit.delegate = walletState
        kit.start()

        moneroKit = kit
        walletState.isConnected = true
    }
}

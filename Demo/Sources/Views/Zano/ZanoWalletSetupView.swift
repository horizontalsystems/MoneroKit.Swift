import SwiftUI
import ZanoKit

struct ZanoWalletSetupView: View {
    @Binding var mnemonicSeed: String
    @Binding var walletId: String
    @Binding var daemonAddress: String
    @Binding var mnemonicType: String
    @Binding var passphrase: String
    @Binding var creationTimestamp: String
    var connectAction: () -> Void

    private let mnemonicTypes = ["BIP39", "Legacy (26 words)"]

    var body: some View {
        Form {
            Section(header: Text("Wallet Recovery")) {
                Picker("Mnemonic Type", selection: $mnemonicType) {
                    ForEach(mnemonicTypes, id: \.self) { type in
                        Text(type).tag(type)
                    }
                }
                TextField("Mnemonic Seed", text: $mnemonicSeed)
                TextField("Passphrase (optional)", text: $passphrase)

                if mnemonicType == "BIP39" {
                    TextField("Creation Timestamp (Unix)", text: $creationTimestamp)
                        .keyboardType(.numberPad)
                }

                TextField("Wallet Name", text: $walletId)
            }
            Section(header: Text("Node Configuration")) {
                TextField("Daemon Address", text: $daemonAddress)
            }
            Button(action: {
                print("[ZanoWalletSetupView] Button tapped")
                connectAction()
            }) {
                Text("Connect or Recover Wallet")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

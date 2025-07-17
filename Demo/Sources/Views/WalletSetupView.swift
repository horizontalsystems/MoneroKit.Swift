import SwiftUI

struct WalletSetupView: View {
    @Binding var mnemonicSeed: String
    @Binding var walletId: String
    @Binding var daemonAddress: String
    @Binding var restoreHeight: String
    var connectAction: () -> Void

    var body: some View {
        Form {
            Section(header: Text("Wallet Recovery (Test Data)")) {
                TextField("Mnemonic Seed", text: $mnemonicSeed)
                TextField("Wallet Name", text: $walletId)
            }
            Section(header: Text("Node Configuration")) {
                TextField("Daemon Address", text: $daemonAddress)
                TextField("Restore Height", text: $restoreHeight)
            }
            Button("Connect or Recover Wallet", action: connectAction)
        }
    }
}

import SwiftUI
import ZanoKit

struct ZanoSubaddressesView: View {
    @Binding var zanoKit: Kit?

    var body: some View {
        List {
            Section(header: Text("Wallet Address")) {
                if let address = zanoKit?.receiveAddress, !address.isEmpty {
                    HStack {
                        Text(address)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(2)
                        Spacer()
                        Button(action: {
                            UIPasteboard.general.string = address
                        }) {
                            Image(systemName: "doc.on.doc")
                        }
                    }
                } else {
                    Text("No address available")
                }
            }
        }
        .navigationTitle("Receive")
    }
}

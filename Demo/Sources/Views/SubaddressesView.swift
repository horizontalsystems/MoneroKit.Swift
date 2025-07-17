import MoneroKit
import SwiftUI

struct SubaddressesView: View {
    @Binding var moneroKit: MoneroKit?
    @State private var newAddressLabel: String = ""

    var body: some View {
        List {
            Section(header: Text("Primary Address")) {
                HStack {
                    Text(moneroKit?.receiveAddress ?? "")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(action: {
                        UIPasteboard.general.string = moneroKit?.receiveAddress
                    }) {
                        Image(systemName: "doc.on.doc")
                    }
                }
            }
        }
        .navigationTitle("My Addresses")
    }
}

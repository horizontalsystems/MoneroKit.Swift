import MoneroKit
import SwiftUI

struct WalletDashboardView: View {
    @Binding var moneroKit: MoneroKit?
    @ObservedObject var walletState: WalletState

    var body: some View {
        List {
            Section(header: Text("Wallet Status")) {
                Text("Synchronized: \(walletState.isSynchronized ? "Yes" : "No")")
                Text("Wallet Height: \(walletState.lastBlockHeight)")
                Text("Balance: \(Double(walletState.balance.spendable) / 1_000_000_000_000) XMR")
            }

            Section(header: Text("Actions")) {
                NavigationLink(destination: SubaddressesView(moneroKit: $moneroKit)) {
                    Text("Receive")
                }
                NavigationLink(destination: SendView(moneroKit: $moneroKit)) {
                    Text("Send")
                }
            }

            Section(header: Text("Transactions")) {
                if walletState.transactions.isEmpty {
                    Text("No transactions yet.")
                } else {
                    ForEach(walletState.transactions, id: \.hash) { tx in
                        VStack(alignment: .leading) {
                            Text("Hash: \(tx.hash)")
                                .font(.caption)
                                .lineLimit(1)
                            Text("Amount: \(Double(tx.amount) / 1_000_000_000_000, specifier: "%.6f") XMR")
                            Text("Direction: \(tx.direction == .out ? "Outgoing" : "Incoming")")
                            if tx.direction == .out {
                                ForEach(tx.transfers, id: \.address) { transfer in
                                    Text("To: \(transfer.address)")
                                        .font(.caption)
                                        .lineLimit(1)
                                }
                            }
                            Text("Date: \(tx.timestamp, formatter: itemFormatter)")
                        }
                    }
                }
            }
        }
        .navigationTitle("Dashboard")
    }
}

private let itemFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .medium
    return formatter
}()

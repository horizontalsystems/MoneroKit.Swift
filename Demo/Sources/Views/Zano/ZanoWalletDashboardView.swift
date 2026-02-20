import ZanoKit
import SwiftUI

struct ZanoWalletDashboardView: View {
    @Binding var zanoKit: Kit?
    @ObservedObject var walletState: Zano_WalletState

    var body: some View {
        List {
            Section(header: Text("Wallet Status")) {
                Text("State: \(stateDescription(walletState.walletState))")
                Text("Wallet Height: \(zanoKit?.lastBlockInfo ?? 0)")
                Text("Balance: \(Double(walletState.balance.unlocked) / 1_000_000_000_000) ZANO")
            }

            Section(header: Text("Actions")) {
                NavigationLink(destination: ZanoSubaddressesView(zanoKit: $zanoKit)) {
                    Text("Receive")
                }
                NavigationLink(destination: ZanoSendView(zanoKit: $zanoKit)) {
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
                            Text("Amount: \(Double(tx.amount) / 1_000_000_000_000, specifier: "%.6f") ZANO")
                            Text("Direction: \(tx.type.zanoDescription)")
                            if let recipient = tx.recipientAddress {
                                Text("To: \(recipient)")
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                            Text("Date: \(Date(timeIntervalSince1970: TimeInterval(tx.timestamp)), formatter: zanoItemFormatter)")
                        }
                    }
                }
            }
        }
        .navigationTitle("Dashboard")
    }

    private func stateDescription(_ state: WalletState) -> String {
        switch state {
        case .connecting: return "Connecting..."
        case let .syncing(progress, remainingBlocksCount): return "Syncing (\(progress)%, \(remainingBlocksCount) blocks remaining)"
        case .synced: return "Synced"
        case let .idle(daemonReachable): return "Idle (daemon \(daemonReachable ? "reachable" : "unreachable"))"
        case let .notSynced(error): return "Not Synced: \(error)"
        }
    }
}

private let zanoItemFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .medium
    return formatter
}()

extension ZanoKit.TransactionType {
    var zanoDescription: String {
        switch self {
        case .incoming: return "Incoming"
        case .outgoing: return "Outgoing"
        case .sentToSelf: return "Sent to Self"
        }
    }
}

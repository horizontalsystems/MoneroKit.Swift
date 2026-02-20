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
            }

            Section(header: Text("Balances")) {
                if walletState.balances.isEmpty {
                    Text("No balances yet")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(walletState.balances, id: \.assetId) { balance in
                        let asset = walletState.assets.first { $0.assetId == balance.assetId }
                        let ticker = asset?.ticker ?? "Unknown"
                        let decimals = asset?.decimalPoint ?? 12

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(ticker)
                                    .font(.headline)
                                if balance.isNative {
                                    Text("(Native)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                            HStack {
                                Text("Total:")
                                Spacer()
                                Text(formatAmount(balance.total, decimals: decimals))
                            }
                            .font(.subheadline)
                            HStack {
                                Text("Unlocked:")
                                Spacer()
                                Text(formatAmount(balance.unlocked, decimals: decimals))
                            }
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Section(header: Text("Actions")) {
                NavigationLink(destination: ZanoSubaddressesView(zanoKit: $zanoKit)) {
                    Text("Receive")
                }
                NavigationLink(destination: ZanoSendView(zanoKit: $zanoKit, walletState: walletState)) {
                    Text("Send")
                }
            }

            Section(header: Text("Transactions")) {
                if walletState.transactions.isEmpty {
                    Text("No transactions yet.")
                } else {
                    ForEach(walletState.transactions, id: \.uid) { tx in
                        let asset = walletState.assets.first { $0.assetId == tx.assetId }
                        let ticker = asset?.ticker ?? "ZANO"
                        let decimals = asset?.decimalPoint ?? 12

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(tx.type.zanoDescription)
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(tx.type == .incoming ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                                    .cornerRadius(4)
                                Spacer()
                                Text(ticker)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Text("\(formatAmount(tx.amount, decimals: decimals)) \(ticker)")
                                .font(.subheadline)
                            Text("Hash: \(tx.hash.prefix(16))...")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            if let recipient = tx.recipientAddress {
                                Text("To: \(recipient.prefix(20))...")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Text(Date(timeIntervalSince1970: TimeInterval(tx.timestamp)), formatter: zanoItemFormatter)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
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

    private func formatAmount(_ amount: Int64, decimals: Int) -> String {
        let divisor = pow(10.0, Double(decimals))
        let value = Double(amount) / divisor
        return String(format: "%.\(min(decimals, 6))f", value)
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

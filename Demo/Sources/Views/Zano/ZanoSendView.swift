import ZanoKit
import SwiftUI

struct ZanoSendView: View {
    @Binding var zanoKit: Kit?
    @ObservedObject var walletState: Zano_WalletState
    @State private var selectedAssetId: String = ZanoAssetId
    @State private var recipientAddress: String = ""
    @State private var amount: String = ""
    @State private var memo: String = ""
    @State private var estimatedFee: UInt64?
    @State private var transactionStatus: String = ""
    @State private var isLoading: Bool = false

    private var selectedAsset: AssetInfo? {
        walletState.assets.first { $0.assetId == selectedAssetId }
    }

    private var selectedBalance: BalanceInfo? {
        walletState.balances.first { $0.assetId == selectedAssetId }
    }

    private var decimals: Double {
        pow(10.0, Double(selectedAsset?.decimalPoint ?? 12))
    }

    private var ticker: String {
        selectedAsset?.ticker ?? "ZANO"
    }

    var body: some View {
        Form {
            Section(header: Text("Asset")) {
                Picker("Select Asset", selection: $selectedAssetId) {
                    ForEach(walletState.assets, id: \.assetId) { asset in
                        let balance = walletState.balances.first { $0.assetId == asset.assetId }
                        let unlocked = balance?.unlocked ?? 0
                        let formattedBalance = formatAmount(unlocked, decimals: asset.decimalPoint)
                        Text("\(asset.ticker) (\(formattedBalance))")
                            .tag(asset.assetId)
                    }
                }

                if let balance = selectedBalance {
                    HStack {
                        Text("Available:")
                        Spacer()
                        Text("\(formatAmount(balance.unlocked, decimals: selectedAsset?.decimalPoint ?? 12)) \(ticker)")
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section(header: Text("Send \(ticker)")) {
                TextField("Recipient Address", text: $recipientAddress)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                TextField("Amount (\(ticker))", text: $amount)
                    .keyboardType(.decimalPad)
                TextField("Comment (Optional)", text: $memo)
            }

            Section(header: Text("Fee")) {
                if let fee = estimatedFee {
                    Text("Network Fee: \(formatAmount(Int64(fee), decimals: 12)) ZANO")
                } else {
                    Text("Network Fee: --")
                        .foregroundColor(.secondary)
                }
                Button("Get Fee Estimate") {
                    estimatedFee = zanoKit?.estimateFee(priority: .default)
                }
            }

            Section {
                Button(action: sendTransaction) {
                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Send")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(isLoading || recipientAddress.isEmpty || amount.isEmpty || estimatedFee == nil)
                .buttonStyle(.borderedProminent)
            }

            if !transactionStatus.isEmpty {
                Section {
                    Text(transactionStatus)
                        .foregroundColor(transactionStatus.contains("Error") || transactionStatus.contains("error") ? .red : .green)
                        .font(.caption)
                }
            }
        }
        .navigationTitle("Send")
        .onAppear {
            // Pre-fetch fee estimate
            estimatedFee = zanoKit?.estimateFee(priority: .default)
        }
    }

    private func formatAmount(_ amount: Int64, decimals: Int) -> String {
        let divisor = pow(10.0, Double(decimals))
        let value = Double(amount) / divisor
        return String(format: "%.\(min(decimals, 6))f", value)
    }

    private func sendTransaction() {
        guard let amountDouble = Double(amount) else {
            transactionStatus = "Error: Invalid amount"
            return
        }

        let amountAtomic = Int(amountDouble * decimals)

        isLoading = true
        transactionStatus = ""

        // Run on background thread to not block UI
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let txHash = try zanoKit?.send(
                    to: recipientAddress,
                    assetId: selectedAssetId,
                    amount: .value(amountAtomic),
                    priority: .default,
                    memo: memo.isEmpty ? nil : memo
                )

                DispatchQueue.main.async {
                    isLoading = false
                    transactionStatus = "Transaction sent!\nHash: \(txHash ?? "unknown")"
                    // Clear form
                    recipientAddress = ""
                    amount = ""
                    memo = ""
                }
            } catch {
                DispatchQueue.main.async {
                    isLoading = false
                    transactionStatus = "Error: \(error.localizedDescription)"
                }
            }
        }
    }
}

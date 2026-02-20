import ZanoKit
import SwiftUI

struct ZanoSendView: View {
    @Binding var zanoKit: Kit?
    @State private var recipientAddress: String = ""
    @State private var amount: String = ""
    @State private var memo: String = ""
    @State private var estimatedFee: UInt64?
    @State private var transactionStatus: String = ""
    @State private var isLoading: Bool = false

    private let decimals: Double = 1_000_000_000_000 // 12 decimals for ZANO

    var body: some View {
        Form {
            Section(header: Text("Send Zano")) {
                TextField("Recipient Address", text: $recipientAddress)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                TextField("Amount (ZANO)", text: $amount)
                    .keyboardType(.decimalPad)
                TextField("Comment (Optional)", text: $memo)
            }

            Section(header: Text("Fee")) {
                if let fee = estimatedFee {
                    Text("Network Fee: \(String(format: "%.6f", Double(fee) / decimals)) ZANO")
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

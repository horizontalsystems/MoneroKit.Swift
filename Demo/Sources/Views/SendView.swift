import MoneroKit
import SwiftUI

struct SendView: View {
    @Binding var moneroKit: MoneroKit?
    @State private var recipientAddress: String = "87mKVhsVc2ETP2g1VCd38mUeKpXkXkPT3B7tQ5aapCc1gNaZZZ5ZkHN5U92pnDom3i7QeJwUqGDCUPv1J51HojY29qZDFaX"
    @State private var amount: String = "0.001"
    @State private var estimatedFee: String?
    @State private var transactionStatus: String = ""

    var body: some View {
        Form {
            Section(header: Text("Send Monero")) {
                TextField("Recipient Address", text: $recipientAddress)
                    .autocapitalization(.none)
                TextField("Amount (XMR)", text: $amount)
                    .keyboardType(.decimalPad)
            }

            Section(header: Text("Fee Estimation")) {
                if let fee = estimatedFee {
                    Text("Estimated Fee: \(fee)")
                }
                Button("Estimate Fee") {
                    if let amountDouble = Double(amount) {
                        let fee = moneroKit?.estimateFee(amount: amountDouble) ?? 0
                        estimatedFee = "\(Double(fee) / 1_000_000_000_000) XMR"
                    }
                }
            }

            Button("Confirm & Send") {
                if let amountDouble = Double(amount) {
                    do {
                        try moneroKit?.send(to: recipientAddress, amount: amountDouble)
                        transactionStatus = "Transaction sent!"
                    } catch {
                        transactionStatus = "Error: \(error.localizedDescription)"
                    }
                }
            }
            .disabled(estimatedFee == nil)

            if !transactionStatus.isEmpty {
                Text(transactionStatus)
                    .foregroundColor(transactionStatus.contains("Error") ? .red : .green)
            }
        }
        .navigationTitle("Send")
    }
}

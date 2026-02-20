//
//  DemoApp.swift
//  Demo
//
//  Created by Esenbek Kydyr uulu on 31/5/25.
//

import MoneroKit
import ZanoKit
import SwiftUI

enum WalletType: String, CaseIterable {
    case monero = "Monero"
    case zano = "Zano"
}

@main
struct DemoApp: App {
    @StateObject private var moneroWalletState = MoneroWalletState()
    @StateObject private var zanoWalletState = Zano_WalletState()
    @State private var moneroKit: MoneroKit.Kit?
    @State private var zanoKit: ZanoKit.Kit?
    @State private var selectedWallet: WalletType = .monero

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 0) {
                Picker("Wallet", selection: $selectedWallet) {
                    ForEach(WalletType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                switch selectedWallet {
                case .monero:
                    ContentView(moneroKit: $moneroKit, walletState: moneroWalletState)
                case .zano:
                    ZanoContentView(zanoKit: $zanoKit, walletState: zanoWalletState)
                }
            }
        }
    }
}

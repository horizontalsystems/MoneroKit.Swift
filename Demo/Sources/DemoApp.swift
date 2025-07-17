//
//  DemoApp.swift
//  Demo
//
//  Created by Esenbek Kydyr uulu on 31/5/25.
//

import MoneroKit
import SwiftUI

@main
struct DemoApp: App {
    @StateObject private var walletState = WalletState()
    @State private var moneroKit: MoneroKit?

    var body: some Scene {
        WindowGroup {
            ContentView(moneroKit: $moneroKit, walletState: walletState)
        }
    }
}

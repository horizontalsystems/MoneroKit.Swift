public enum ZanoWallet {
    case bip39(seed: [String], passphrase: String, creationTimestamp: UInt64)
    case legacy(seed: [String], passphrase: String)

    mutating func clear() {
        switch self {
        case .bip39:
                self = .bip39(seed: [], passphrase: "", creationTimestamp: 0)
        case .legacy:
            self = .legacy(seed: [], passphrase: "")
        }
    }
}

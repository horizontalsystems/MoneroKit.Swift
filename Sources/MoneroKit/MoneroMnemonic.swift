public enum MoneroMnemonic {
    case bip39(seed: [String], passphrase: String)
    case legacy(seed: [String], passphrase: String)
    case polyseed(seed: [String], passphrase: String)

    mutating func clear() {
        switch self {
        case .bip39:
            self = .bip39(seed: [], passphrase: "")
        case .legacy:
            self = .legacy(seed: [], passphrase: "")
        case .polyseed:
            self = .polyseed(seed: [], passphrase: "")
        }
    }
}

public enum MoneroMnemonic {
    case bip39(seed: [String], passphrase: String)
    case legacy(seed: [String], passphrase: String)
    case polyseed(seed: [String], passphrase: String)
}

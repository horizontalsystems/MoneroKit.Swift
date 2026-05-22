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

    var restoreHeight: UInt64 {
        // Calculate restore height based on wallet type
        let creationTimestamp: UInt64
        switch self {
        case let .bip39(_, _, ts):
            creationTimestamp = ts
        case let .legacy(seed, _):
            // Timestamp word is at index 24 for both:
            // - 25 words: 24 seed words + 1 timestamp word
            // - 26 words: 24 seed words + 1 timestamp word + 1 checksum word
            let timestampWord = seed.count >= 25 ? seed[24] : ""
            creationTimestamp = ZanoWalletAPI.getTimestampFromWord(timestampWord)
        }

        return UInt64(RestoreHeight.getHeight(timestamp: creationTimestamp))
    }
}

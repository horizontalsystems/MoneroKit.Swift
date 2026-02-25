import BigInt
import CZano
import Foundation
import HdWalletKit
import HsToolKit

private let saltPrefix = "mnemonic"
private let coinType: UInt32 = 128
private let ed25519CurveOrderHex = "1000000000000000000000000000000014DEF9DEA2F79CD65812631A5CF5D3ED"

func stringFromCString(_ cString: UnsafePointer<Int8>!) -> String? {
    guard let cString else { return nil }
    let swiftString = String(cString: cString)
    ZANO_free(UnsafeMutableRawPointer(mutating: cString))
    return swiftString
}

/// Derives a 32-byte secret derivation hex from BIP39 mnemonic for use with Zano's restore_from_derivations
func secretDerivationFromBip39(mnemonic: [String], passphrase: String = "") throws -> String {
    guard let seed = Mnemonic.seed(mnemonic: mnemonic, prefix: saltPrefix, passphrase: passphrase) else {
        throw ZanoKitError.invalidSeed
    }

    let hdWallet = HDWallet(seed: seed, coinType: coinType, xPrivKey: HDExtendedKeyVersion.xprv.rawValue)
    let secp256kPrivateKey = try hdWallet.privateKey(account: 0, index: 0, chain: .external).raw
    let secretKey = Data(reduceECKey(secp256kPrivateKey.bytes))

    return secretKey.hs.hex
}

func reduceECKey(_ buffer: [UInt8]) -> [UInt8] {
    let curveOrder = BigUInt(ed25519CurveOrderHex, radix: 16)!
    let bigNumber = readBytes(buffer)

    var result = bigNumber % curveOrder

    // Convert result (BigUInt) to little-endian [UInt8] with 32 bytes
    var resultBuffer = [UInt8](repeating: 0, count: 32)
    for i in 0 ..< 32 {
        resultBuffer[i] = UInt8(result & 0xFF)
        result >>= 8
    }

    return resultBuffer
}

func readBytes(_ bytes: [UInt8]) -> BigUInt {
    var result = BigUInt(0)
    for (i, byte) in bytes.enumerated() {
        result += BigUInt(byte) << (8 * i)
    }
    return result
}

extension String {
    func prettyPrintedJSON() -> String? {
        guard let data = data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: data),
              let prettyData = try? JSONSerialization.data(withJSONObject: jsonObject, options: .prettyPrinted),
              let prettyString = String(data: prettyData, encoding: .utf8)
        else {
            return nil
        }
        return prettyString
    }
}

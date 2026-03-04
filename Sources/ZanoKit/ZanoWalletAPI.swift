import CZano
import Foundation
import HsToolKit

/// Wrapper for Zano PlainWallet C API with logging support
class ZanoWalletAPI {
    private let logger: Logger?

    init(logger: Logger?) {
        self.logger = logger
    }

    // MARK: - Logging Helpers

    private func logRequest(_ method: String, params: String? = nil) {
        logger?.debug("📤 [ZANO API] \(method)")
        if let params {
            logger?.debug("   Request: \(params.prettyPrintedJSON() ?? params)")
        }
    }

    private func logResponse(_ method: String, response: String?) {
        if let response {
            logger?.debug("📥 [ZANO API] \(method) Response:")
            logger?.debug("   \(response.prettyPrintedJSON() ?? response)")
        } else {
            logger?.debug("📥 [ZANO API] \(method) Response: nil")
        }
    }

    // MARK: - Library Initialization

    func initLibrary(daemonAddress: String, workingDir: String, logLevel: Int32) -> String? {
        logRequest("ZANO_PlainWallet_init", params: """
        {
            "daemon_address": "\(daemonAddress)",
            "working_dir": "\(workingDir)",
            "log_level": \(logLevel)
        }
        """)

        let result = stringFromCString(ZANO_PlainWallet_init(
            (daemonAddress as NSString).utf8String,
            (workingDir as NSString).utf8String,
            logLevel
        ))

        logResponse("ZANO_PlainWallet_init", response: result)
        return result
    }

    // MARK: - Wallet Existence Check

    func walletExists(path: String) -> Bool {
        logRequest("ZANO_PlainWallet_isWalletExist", params: "{\"path\": \"\(path)\"}")
        let exists = ZANO_PlainWallet_isWalletExist((path as NSString).utf8String)
        logResponse("ZANO_PlainWallet_isWalletExist", response: "\(exists)")
        return exists
    }

    // MARK: - Wallet Open

    func openWallet(path: String, password: String) -> String? {
        logRequest("ZANO_PlainWallet_open", params: """
        {
            "path": "\(path)",
            "password": "***"
        }
        """)

        let result = stringFromCString(ZANO_PlainWallet_open(
            (path as NSString).utf8String,
            (password as NSString).utf8String
        ))

        logResponse("ZANO_PlainWallet_open", response: result)
        return result
    }

    // MARK: - Wallet Restore (Legacy)

    func restoreWallet(seed: String, path: String, password: String, passphrase: String, seedWordsCount: Int) -> String? {
        logRequest("ZANO_PlainWallet_restore", params: """
        {
            "seed": "*** (\(seedWordsCount) words)",
            "path": "\(path)",
            "password": "***",
            "passphrase": "\(passphrase.isEmpty ? "(empty)" : "***")"
        }
        """)

        let result = stringFromCString(ZANO_PlainWallet_restore(
            (seed as NSString).utf8String,
            (path as NSString).utf8String,
            (password as NSString).utf8String,
            (passphrase as NSString).utf8String
        ))

        logResponse("ZANO_PlainWallet_restore", response: result)
        return result
    }

    // MARK: - Sync Call (for global operations like restore_from_derivations)

    func syncCall(method: String, instanceId: UInt64, params: String, logParams: String? = nil) -> String? {
        logRequest("ZANO_PlainWallet_syncCall(\(method))", params: logParams ?? params)

        let result = stringFromCString(ZANO_PlainWallet_syncCall(
            (method as NSString).utf8String,
            instanceId,
            (params as NSString).utf8String
        ))

        logResponse("ZANO_PlainWallet_syncCall(\(method))", response: result)
        return result
    }

    // MARK: - Wallet Invoke (for wallet-specific operations)

    func invoke(walletId: Int64, method: String, params: [String: Any]? = nil) -> String? {
        var request: [String: Any] = ["method": method]
        if let params {
            request["params"] = params
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: request),
              let jsonString = String(data: jsonData, encoding: .utf8)
        else {
            logger?.error("Failed to serialize invoke request for method: \(method)")
            return nil
        }

        logRequest("ZANO_PlainWallet_invoke(\(method))", params: jsonString)

        let result = stringFromCString(ZANO_PlainWallet_invoke(
            walletId,
            (jsonString as NSString).utf8String
        ))

        logResponse("ZANO_PlainWallet_invoke(\(method))", response: result)
        return result
    }

    // MARK: - Wallet Status

    func getWalletStatus(walletId: Int64) -> String? {
        logRequest("ZANO_PlainWallet_getWalletStatus", params: "{\"wallet_id\": \(walletId)}")

        let result = stringFromCString(ZANO_PlainWallet_getWalletStatus(walletId))

        logResponse("ZANO_PlainWallet_getWalletStatus", response: result)
        return result
    }

    // MARK: - Close Wallet

    func closeWallet(walletId: Int64) -> String? {
        logRequest("ZANO_PlainWallet_closeWallet", params: "{\"wallet_id\": \(walletId)}")

        let result = stringFromCString(ZANO_PlainWallet_closeWallet(walletId))

        logResponse("ZANO_PlainWallet_closeWallet", response: result)

        ZANO_PlainWallet_deinit()

        return result
    }

    // MARK: - Address Validation

    func getAddressInfo(address: String) -> String? {
        logRequest("ZANO_PlainWallet_getAddressInfo", params: "{\"address\": \"\(address)\"}")

        let result = stringFromCString(ZANO_PlainWallet_getAddressInfo(
            (address as NSString).utf8String
        ))

        logResponse("ZANO_PlainWallet_getAddressInfo", response: result)
        return result
    }

    // MARK: - Fee Estimation

    func getCurrentTxFee(priority: UInt64) -> UInt64 {
        logRequest("ZANO_PlainWallet_getCurrentTxFee", params: "{\"priority\": \(priority)}")

        let fee = ZANO_PlainWallet_getCurrentTxFee(priority)

        logResponse("ZANO_PlainWallet_getCurrentTxFee", response: "\(fee)")
        return fee
    }

    /// Static method for fee estimation (doesn't require logging)
    static func estimateFee(priority: UInt64) -> UInt64 {
        ZANO_PlainWallet_getCurrentTxFee(priority)
    }

    // MARK: - Timestamp from Seed Word

    /// Get timestamp embedded in the last word of a legacy Zano seed
    static func getTimestampFromWord(_ word: String) -> UInt64 {
        var passwordUsed = false
        let timestamp = ZANO_getTimestampFromWord(
            (word as NSString).utf8String,
            &passwordUsed
        )

        return timestamp
    }
}

// MARK: - Response Parsing Helpers

extension ZanoWalletAPI {
    /// Parse a JSON response and extract the result
    func parseResponse(_ json: String?) -> (result: [String: Any]?, error: (code: Int, message: String)?) {
        guard let json,
              let data = json.data(using: .utf8),
              let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return (nil, (code: -1, message: "Invalid JSON response"))
        }

        // Check for error
        if let error = response["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? -1
            let message = error["message"] as? String ?? "Unknown error"
            return (nil, (code: code, message: message))
        }

        // Return result
        if let result = response["result"] as? [String: Any] {
            return (result, nil)
        }

        return (nil, nil)
    }

    /// Check if address is valid
    func isValidAddress(_ address: String) -> Bool {
        guard let resultJson = getAddressInfo(address: address),
              let data = resultJson.data(using: .utf8),
              let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }
        return response["valid"] as? Bool ?? false
    }
}

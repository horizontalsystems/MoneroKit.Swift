import Foundation

public struct NodePingResult {
    /// Latency thresholds for UI coloring, matching the Android kit.
    public static let pingGood: TimeInterval = 0.333
    public static let pingMedium: TimeInterval = 0.667

    public let node: Node
    /// Wall-clock time of one getlastblockheader round-trip; nil = unreachable.
    public let responseTime: TimeInterval?
    /// The node's chain tip. 0 when unreachable or unparseable. Compare against the highest
    /// reported height to reject lagging nodes before auto-selecting by latency.
    public let height: UInt64
    public let majorVersion: Int
    /// Reachable, speaks JSON-RPC 2.0, and reports a plausible chain state.
    public let isValid: Bool

    public var isReachable: Bool {
        responseTime != nil
    }
}

/// Measures response time and chain height of daemon RPC nodes with a single
/// `getlastblockheader` JSON-RPC call per node. Static and independent of any Kit instance.
public enum NodePinger {
    public static func ping(nodes: [Node], timeout: TimeInterval = 5) async -> [NodePingResult] {
        await withTaskGroup(of: (Int, NodePingResult).self) { group in
            for (index, node) in nodes.enumerated() {
                group.addTask {
                    await (index, ping(node: node, timeout: timeout))
                }
            }

            var results = [NodePingResult?](repeating: nil, count: nodes.count)
            for await (index, result) in group {
                results[index] = result
            }

            return results.compactMap { $0 }
        }
    }

    public static func ping(node: Node, timeout: TimeInterval = 5) async -> NodePingResult {
        guard let url = probeUrl(for: node) else {
            return NodePingResult(node: node, responseTime: nil, height: 0, majorVersion: 0, isValid: false)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": "0", "method": "getlastblockheader"])
        request.timeoutInterval = timeout

        if let login = node.login, let password = node.password,
           let credentials = "\(login):\(password)".data(using: .utf8)
        {
            request.setValue("Basic \(credentials.base64EncodedString())", forHTTPHeaderField: "Authorization")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let start = Date()

        do {
            let (data, response) = try await session.data(for: request)
            let elapsed = Date().timeIntervalSince(start)

            guard let httpResponse = response as? HTTPURLResponse, (200 ..< 300).contains(httpResponse.statusCode) else {
                // The server answered, but the RPC is unusable (auth required, proxy error, ...).
                return NodePingResult(node: node, responseTime: elapsed, height: 0, majorVersion: 0, isValid: false)
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["jsonrpc"] as? String == "2.0",
                  let result = json["result"] as? [String: Any],
                  let header = result["block_header"] as? [String: Any],
                  let height = (header["height"] as? NSNumber)?.uint64Value
            else {
                return NodePingResult(node: node, responseTime: elapsed, height: 0, majorVersion: 0, isValid: false)
            }

            let majorVersion = (header["major_version"] as? NSNumber)?.intValue ?? 0

            return NodePingResult(
                node: node,
                responseTime: elapsed,
                height: height,
                majorVersion: majorVersion,
                isValid: height > 0 && majorVersion >= 14
            )
        } catch {
            return NodePingResult(node: node, responseTime: nil, height: 0, majorVersion: 0, isValid: false)
        }
    }

    /// Builds the /json_rpc probe URL. Node URLs may carry an explicit scheme or be bare
    /// "host:port" strings; for the latter the scheme is inferred from the port the way the
    /// Android kit does (443/18443 = HTTPS, anything else = plain HTTP).
    static func probeUrl(for node: Node) -> URL? {
        let raw = node.url.absoluteString

        var components: URLComponents?
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            components = URLComponents(string: raw)
        } else {
            components = URLComponents(string: "http://\(raw)")
            if let port = components?.port, port == 443 || port == 18443 {
                components?.scheme = "https"
            }
        }

        guard var components, components.host != nil else { return nil }
        components.path = "/json_rpc"
        components.query = nil

        return components.url
    }
}

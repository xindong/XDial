import Darwin
import Foundation

struct TransparentProxyRemoteNetwork: Codable, Equatable, Hashable, Sendable {
    let address: String
    let prefixLength: Int

    enum CodingKeys: String, CodingKey {
        case address
        case prefixLength = "prefix_length"
    }
}

enum TransparentProxyNetworkRulePlanError: LocalizedError, Equatable {
    case tooManyDirectExcludedNetworks
    case invalidDirectExcludedNetwork

    var errorDescription: String? {
        switch self {
        case .tooManyDirectExcludedNetworks:
            return "透明代理直连排除网段数量超出上限"
        case .invalidDirectExcludedNetwork:
            return "透明代理直连排除网段包含无效或非私网地址"
        }
    }
}

enum TransparentProxyNetworkRulePlan {
    static let maximumDirectExcludedNetworkCount = 128

    /// Addresses whose meaning depends on the originating interface or local
    /// broadcast domain cannot retain that meaning after loopback SOCKS relay.
    /// Private/LAN unicast exclusions are never hardcoded here; Go compiles
    /// Scenario-proven Direct-only private subnets into `directExcludedNetworks`.
    static let interfaceScopedRemoteNetworks = [
        TransparentProxyRemoteNetwork(
            address: "169.254.0.0",
            prefixLength: 16
        ),
        TransparentProxyRemoteNetwork(
            address: "224.0.0.0",
            prefixLength: 4
        ),
        TransparentProxyRemoteNetwork(
            address: "255.255.255.255",
            prefixLength: 32
        ),
        TransparentProxyRemoteNetwork(
            address: "fe80::",
            prefixLength: 10
        ),
        TransparentProxyRemoteNetwork(
            address: "ff00::",
            prefixLength: 8
        ),
    ]

    /// Validates Scenario-compiled Direct private/LAN exclusions returned by Go.
    /// Defense-in-depth: only canonical RFC1918 and IPv6 ULA prefixes are accepted,
    /// so public internet, Tailnet/CGNAT (`100.64.0.0/10`), and `/0` can never
    /// bypass the transparent proxy even on malformed input.
    static func validateDirectExcludedNetworks(
        _ networks: [TransparentProxyRemoteNetwork]
    ) throws -> [TransparentProxyRemoteNetwork] {
        guard networks.count <= maximumDirectExcludedNetworkCount else {
            throw TransparentProxyNetworkRulePlanError
                .tooManyDirectExcludedNetworks
        }
        var seen = Set<TransparentProxyRemoteNetwork>()
        var validated: [TransparentProxyRemoteNetwork] = []
        validated.reserveCapacity(networks.count)
        for network in networks {
            guard isValidPrivateLANNetwork(network) else {
                throw TransparentProxyNetworkRulePlanError
                    .invalidDirectExcludedNetwork
            }
            if seen.insert(network).inserted {
                validated.append(network)
            }
        }
        return validated
    }

    /// Combines the static interface-scoped exclusions with the active session's
    /// Scenario-verified Direct private/LAN exclusions, preserving deterministic order.
    static func excludedRemoteNetworks(
        directExcludedNetworks: [TransparentProxyRemoteNetwork]
    ) -> [TransparentProxyRemoteNetwork] {
        var seen = Set(interfaceScopedRemoteNetworks)
        var combined = interfaceScopedRemoteNetworks
        combined.reserveCapacity(
            interfaceScopedRemoteNetworks.count + directExcludedNetworks.count
        )
        for network in directExcludedNetworks where seen.insert(network).inserted {
            combined.append(network)
        }
        return combined
    }

    private static func isValidPrivateLANNetwork(
        _ network: TransparentProxyRemoteNetwork
    ) -> Bool {
        let address = network.address
        guard !address.isEmpty,
              address.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
            return false
        }

        var addr4 = in_addr()
        if inet_pton(AF_INET, address, &addr4) == 1 {
            guard network.prefixLength >= 8 && network.prefixLength <= 32 else {
                return false
            }
            var canonical = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(
                AF_INET,
                &addr4,
                &canonical,
                socklen_t(canonical.count)
            ) != nil,
                String(cString: canonical) == address else {
                return false
            }
            let host = UInt32(bigEndian: addr4.s_addr)
            let mask: UInt32 = network.prefixLength == 32
                ? UInt32.max
                : ~((UInt32(1) << (32 - network.prefixLength)) - 1)
            guard (host & mask) == host else {
                return false
            }
            let is10 = network.prefixLength >= 8
                && (host & 0xFF00_0000) == 0x0A00_0000
            let is172 = network.prefixLength >= 12
                && (host & 0xFFF0_0000) == 0xAC10_0000
            let is192 = network.prefixLength >= 16
                && (host & 0xFFFF_0000) == 0xC0A8_0000
            return is10 || is172 || is192
        }

        var addr6 = in6_addr()
        if inet_pton(AF_INET6, address, &addr6) == 1 {
            guard network.prefixLength >= 7 && network.prefixLength <= 128 else {
                return false
            }
            var canonical = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(
                AF_INET6,
                &addr6,
                &canonical,
                socklen_t(canonical.count)
            ) != nil,
                String(cString: canonical) == address else {
                return false
            }
            let bytes = withUnsafeBytes(of: addr6) { Array($0) }
            guard bytes.count == 16, (bytes[0] & 0xFE) == 0xFC else {
                return false
            }
            for bitIndex in network.prefixLength ..< 128 {
                let byte = bytes[bitIndex / 8]
                let bitMask: UInt8 = 1 << (7 - (bitIndex % 8))
                if (byte & bitMask) != 0 {
                    return false
                }
            }
            return true
        }

        return false
    }
}

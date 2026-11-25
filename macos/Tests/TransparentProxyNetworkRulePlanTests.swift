import XCTest

final class TransparentProxyNetworkRulePlanTests: XCTestCase {
    func testOnlyInterfaceScopedAddressesBypassTransparentProxy() {
        XCTAssertEqual(
            TransparentProxyNetworkRulePlan.interfaceScopedRemoteNetworks,
            [
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
        )
    }

    func testRoutablePrivateAndOverlayUnicastRemainCaptured() {
        let addresses = Set(
            TransparentProxyNetworkRulePlan.interfaceScopedRemoteNetworks
                .map(\.address)
        )

        for forbidden in [
            "10.0.0.0",
            "100.64.0.0",
            "172.16.0.0",
            "192.168.0.0",
            "fc00::",
        ] {
            XCTAssertFalse(addresses.contains(forbidden))
        }
    }

    func testValidatesAndMergesDirectExcludedPrivateNetworks() throws {
        let direct = [
            TransparentProxyRemoteNetwork(
                address: "192.168.0.0",
                prefixLength: 16
            ),
            TransparentProxyRemoteNetwork(
                address: "172.20.10.0",
                prefixLength: 28
            ),
            TransparentProxyRemoteNetwork(
                address: "10.0.1.0",
                prefixLength: 24
            ),
            TransparentProxyRemoteNetwork(
                address: "fd00::",
                prefixLength: 8
            ),
            // Duplicate entry should be deduplicated cleanly.
            TransparentProxyRemoteNetwork(
                address: "192.168.0.0",
                prefixLength: 16
            ),
        ]

        let validated = try TransparentProxyNetworkRulePlan
            .validateDirectExcludedNetworks(direct)
        XCTAssertEqual(validated.count, 4)

        let combined = TransparentProxyNetworkRulePlan.excludedRemoteNetworks(
            directExcludedNetworks: validated
        )
        XCTAssertEqual(
            combined,
            TransparentProxyNetworkRulePlan.interfaceScopedRemoteNetworks
                + validated
        )
    }

    func testRejectsPublicTailnetMalformedOrNonCanonicalDirectExclusions() {
        let invalidCases: [TransparentProxyRemoteNetwork] = [
            // Default route / public ranges must never be accepted.
            TransparentProxyRemoteNetwork(address: "0.0.0.0", prefixLength: 0),
            TransparentProxyRemoteNetwork(address: "8.8.8.0", prefixLength: 24),
            TransparentProxyRemoteNetwork(address: "1.1.1.1", prefixLength: 32),
            TransparentProxyRemoteNetwork(address: "2001:db8::", prefixLength: 32),
            // Tailnet / CGNAT must never bypass XDial.
            TransparentProxyRemoteNetwork(address: "100.64.0.0", prefixLength: 10),
            TransparentProxyRemoteNetwork(address: "100.100.100.100", prefixLength: 32),
            // Interface-scoped / loopback are not valid direct LAN exclusions.
            TransparentProxyRemoteNetwork(address: "127.0.0.0", prefixLength: 8),
            TransparentProxyRemoteNetwork(address: "169.254.0.0", prefixLength: 16),
            TransparentProxyRemoteNetwork(address: "fe80::", prefixLength: 10),
            // Prefix shorter than private supernet would spill into public space.
            TransparentProxyRemoteNetwork(address: "192.168.0.0", prefixLength: 8),
            TransparentProxyRemoteNetwork(address: "172.16.0.0", prefixLength: 11),
            TransparentProxyRemoteNetwork(address: "10.0.0.0", prefixLength: 7),
            TransparentProxyRemoteNetwork(address: "fc00::", prefixLength: 6),
            // Non-zero host bits or non-canonical formatting.
            TransparentProxyRemoteNetwork(address: "192.168.68.83", prefixLength: 22),
            TransparentProxyRemoteNetwork(address: "fd00::1", prefixLength: 64),
            TransparentProxyRemoteNetwork(address: "FD00::", prefixLength: 8),
            TransparentProxyRemoteNetwork(address: " 192.168.0.0", prefixLength: 16),
            TransparentProxyRemoteNetwork(address: "not-an-ip", prefixLength: 24),
        ]

        for invalid in invalidCases {
            XCTAssertThrowsError(
                try TransparentProxyNetworkRulePlan
                    .validateDirectExcludedNetworks([invalid]),
                "Expected rejection for \(invalid)"
            )
        }
    }

    func testRejectsUnboundedDirectExclusionList() {
        let tooMany = (0 ... TransparentProxyNetworkRulePlan.maximumDirectExcludedNetworkCount)
            .map { index in
                TransparentProxyRemoteNetwork(
                    address: "192.168.\(index / 256).\(index % 256)",
                    prefixLength: 32
                )
            }
        XCTAssertThrowsError(
            try TransparentProxyNetworkRulePlan
                .validateDirectExcludedNetworks(tooMany)
        ) { error in
            XCTAssertEqual(
                error as? TransparentProxyNetworkRulePlanError,
                .tooManyDirectExcludedNetworks
            )
        }
    }

    func testDecodesGoSessionEnvelopeDirectExcludedNetworksSchema() throws {
        let json = Data(#"""
        [
          {"address": "192.168.0.0", "prefix_length": 16},
          {"address": "fd12:3456::", "prefix_length": 48}
        ]
        """#.utf8)
        let decoded = try JSONDecoder().decode(
            [TransparentProxyRemoteNetwork].self,
            from: json
        )
        let validated = try TransparentProxyNetworkRulePlan
            .validateDirectExcludedNetworks(decoded)
        XCTAssertEqual(
            validated,
            [
                TransparentProxyRemoteNetwork(
                    address: "192.168.0.0",
                    prefixLength: 16
                ),
                TransparentProxyRemoteNetwork(
                    address: "fd12:3456::",
                    prefixLength: 48
                ),
            ]
        )
    }

    func testScenarioSwitchReplacesPreviousDirectExclusions() throws {
        let overseasExclusions = try TransparentProxyNetworkRulePlan
            .validateDirectExcludedNetworks([
                TransparentProxyRemoteNetwork(
                    address: "192.168.0.0",
                    prefixLength: 16
                ),
            ])
        let overseasRules = TransparentProxyNetworkRulePlan
            .excludedRemoteNetworks(directExcludedNetworks: overseasExclusions)
        XCTAssertTrue(
            overseasRules.contains(
                TransparentProxyRemoteNetwork(
                    address: "192.168.0.0",
                    prefixLength: 16
                )
            )
        )

        // Switching to a VPN-all scenario clears Scenario-derived direct exclusions,
        // leaving only interface-scoped exclusions.
        let allVPNRules = TransparentProxyNetworkRulePlan
            .excludedRemoteNetworks(directExcludedNetworks: [])
        XCTAssertEqual(
            allVPNRules,
            TransparentProxyNetworkRulePlan.interfaceScopedRemoteNetworks
        )

        // Network change updates direct exclusions to the new Underlay subnet.
        let hotspotExclusions = try TransparentProxyNetworkRulePlan
            .validateDirectExcludedNetworks([
                TransparentProxyRemoteNetwork(
                    address: "172.20.10.0",
                    prefixLength: 28
                ),
            ])
        let hotspotRules = TransparentProxyNetworkRulePlan
            .excludedRemoteNetworks(directExcludedNetworks: hotspotExclusions)
        XCTAssertFalse(
            hotspotRules.contains(
                TransparentProxyRemoteNetwork(
                    address: "192.168.0.0",
                    prefixLength: 16
                )
            )
        )
        XCTAssertTrue(
            hotspotRules.contains(
                TransparentProxyRemoteNetwork(
                    address: "172.20.10.0",
                    prefixLength: 28
                )
            )
        )
    }
}

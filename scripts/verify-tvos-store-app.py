#!/usr/bin/env python3
"""Check the signed XD tvOS app and its authorized preset from an xcarchive or an exported IPA."""
import argparse
import json
import plistlib
import subprocess
from pathlib import Path

BUNDLE = "com.xd.xdial.ios"
TEAM = "SX9RG894L5"
GROUP = "group." + BUNDLE
KEYCHAIN = TEAM + ".com.xd.xdial.shared"


def require(ok, message):
    if not ok:
        raise SystemExit(message)


def info(path):
    return plistlib.loads((path / "Info.plist").read_bytes())


def verify_target(path, bundle_id, markers):
    metadata = info(path)
    require(metadata["CFBundleIdentifier"] == bundle_id, f"{path.name}: unexpected bundle ID")
    require(metadata["CFBundleSupportedPlatforms"] == ["AppleTVOS"], f"{path.name}: device build required")
    require(metadata.get("XDialTunnelBundleIdentifier") == BUNDLE + ".tunnel" and
            metadata.get("XDialAppGroupIdentifier") == GROUP and
            metadata.get("XDialSharedKeychainAccessGroup") == KEYCHAIN,
            f"{path.name}: incorrect runtime identity")
    require((path / "PrivacyInfo.xcprivacy").is_file(), f"{path.name}: privacy manifest missing")
    subprocess.run(["codesign", "--verify", "--strict", str(path)], check=True)
    signed = plistlib.loads(subprocess.check_output(["codesign", "-d", "--entitlements", "-", "--xml", str(path)]))
    require(signed.get("application-identifier") == TEAM + "." + bundle_id and
            signed.get("com.apple.developer.team-identifier") == TEAM and not signed.get("get-task-allow"),
            f"{path.name}: incorrect signing identity or development signing")
    for key, value in [("com.apple.security.application-groups", GROUP),
                       ("keychain-access-groups", KEYCHAIN),
                       ("com.apple.developer.networking.networkextension", "packet-tunnel-provider")]:
        require(value in signed.get(key, []), f"{path.name}: missing signed entitlement {key}")
    binary = (path / metadata["CFBundleExecutable"]).read_bytes()
    verify_markers(path, binary, markers)
    return metadata


def verify_markers(path, binary, markers):
    for marker in markers:
        require(marker.encode() in binary, f"{path.name}: missing production engine symbol {marker}")
    for marker in ("NoopTunnelEngine", "FakeTunnelEngine", "LANShareSettings", "AddLANShareInbound", "core/macgateway."):
        require(marker.encode() not in binary, f"{path.name}: unexpected engine/experiment symbol {marker}")


def verify_seed(app, authority=None):
    private = app / "PrivateConfig"
    for path in app.rglob("*"):
        relative = path.relative_to(app)
        # Signing credentials are forbidden in every mode. Enterprise presets
        # may occupy only the exact directory consumed by MobileSeed.
        require(path.suffix.lower() not in {".p8", ".p12", ".pem", ".key", ".mobileprovision"}
                or path.name == "embedded.mobileprovision",
                f"Signing input found: {relative}")
        protected = (path.name.lower() in {"privateconfig", "seed.json", "rulesets", "seedprofile"}
                     or path.suffix.lower() == ".srs")
        inside = path == private or private in path.parents
        require(not protected or (authority is not None and inside),
                f"Unexpected preset resource: {relative}")
        if inside:
            parts = relative.parts[1:]
            allowed = (parts == () or parts == ("Seed.json",) or parts == ("RuleSets",)
                       or (len(parts) == 2 and parts[0] == "RuleSets"
                           and path.suffix in {".srs", ".json"}))
            require(allowed and not path.is_symlink(), f"Unexpected private input: {relative}")
    if authority is None:
        return
    # Byte equality includes revision and migration history; semantic/rule
    # validation below proves the actual payload is usable by the mobile reader.
    source = authority / "Seed.json"
    packaged = private / "Seed.json"
    require(source.is_file() and packaged.is_file(), "Authorized and packaged seeds are required")
    require(source.read_bytes() == packaged.read_bytes(), "Packaged seed differs from authorized source")
    try:
        seed = json.loads(packaged.read_bytes())
    except (ValueError, UnicodeError):
        raise SystemExit("Invalid mobile seed JSON") from None
    require(isinstance(seed, dict), "Mobile seed must be an object")
    require(seed.get("format") == "xdial-mobile-seed" and type(seed.get("revision")) is int
            and seed["revision"] > 0, "Invalid mobile seed revision or format")
    def rule_files(directory):
        return {p.name: p.read_bytes() for p in directory.glob("*")
                if p.is_file() and p.suffix in {".srs", ".json"}}
    require(rule_files(authority / "RuleSets") == rule_files(private / "RuleSets"),
            "Packaged rule files differ from authorized source")
    result = subprocess.run(["go", "run", "./cmd/xdial-seed", "check", "--authority", str(authority.resolve()),
                             "--platform", "tvos", "--bundle", str(app.resolve())],
                            cwd=Path(__file__).resolve().parents[1], capture_output=True)
    # Diff output can contain private routing data: keep it out of public logs.
    require(result.returncode == 0, "Packaged seed/rules failed authorized-source validation")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--seed-authority", type=Path,
                        help="authorized private preset directory; required for a company package")
    args = parser.parse_args()
    app = args.app
    host = verify_target(app, BUNDLE, ["GoEngine", "TunnelManager", "NETunnelProviderManager"])
    extensions = list((app / "PlugIns").glob("*.appex"))
    require(len(extensions) == 1, "Expected one embedded packet tunnel")
    provider = verify_target(extensions[0], BUNDLE + ".tunnel",
                             ["PacketTunnelProvider", "NEPacketTunnelProvider", "LibboxNew"])
    require(provider.get("NSExtension", {}).get("NSExtensionPointIdentifier") ==
            "com.apple.networkextension.packet-tunnel", "Incorrect extension point")
    for key in ("CFBundleVersion", "CFBundleShortVersionString"):
        require(host[key] == provider[key], "Host and provider version mismatch")
    subprocess.run(["python3", Path(__file__).with_name("verify-shared-libbox.py"), app], check=True)
    framework = app / "Frameworks/Libbox.framework"
    subprocess.run(["codesign", "--verify", "--strict", str(framework)], check=True)
    verify_markers(framework, (framework / "Libbox").read_bytes(), ["libbox.(*Libbox).Start"])
    verify_seed(app, args.seed_authority)
    require((app / "Assets.car").is_file(), "Store artwork missing")
    require((app / "ThirdPartyNotices.txt").is_file(), "Third-party notices missing")
    print(f"Verified tvOS {host['CFBundleShortVersionString']} ({host['CFBundleVersion']}), "
          f"{host['CFBundleIdentifier']} and embedded packet tunnel")


if __name__ == "__main__":
    main()

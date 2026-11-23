#!/usr/bin/env python3
"""Link gomobile's static slices into an extension-safe dynamic XCFramework."""
import argparse
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path


def build_slice(root, library, scratch):
    platform = library["SupportedPlatform"]
    simulator = library.get("SupportedPlatformVariant") == "simulator"
    sdk, minimum, os_name = {
        "ios": ("iphonesimulator" if simulator else "iphoneos", "17.0", "ios"),
        "tvos": ("appletvsimulator" if simulator else "appletvos", "17.0", "tvos"),
        "macos": ("macosx", "15.0", "macos"),
    }[platform]
    source = root / library["LibraryIdentifier"] / library["LibraryPath"]
    framework = scratch / library["LibraryIdentifier"] / source.name
    mac = platform == "macos"
    contents = framework / "Versions/A" if mac else framework
    contents.mkdir(parents=True)
    for directory in ("Modules", "Headers"):
        shutil.copytree(source / directory, contents / directory)
    resources = contents / "Resources" if mac else contents
    resources.mkdir(exist_ok=True)
    info = dict(CFBundleIdentifier="com.xd.xdial.libbox", CFBundleExecutable="Libbox",
                CFBundleName="Libbox", CFBundlePackageType="FMWK", CFBundleVersion="1",
                CFBundleShortVersionString="1.0", CFBundleInfoDictionaryVersion="6.0")
    info["LSMinimumSystemVersion" if mac else "MinimumOSVersion"] = minimum
    info["CFBundleSupportedPlatforms"] = [{"iphoneos": "iPhoneOS", "iphonesimulator": "iPhoneSimulator",
        "appletvos": "AppleTVOS", "appletvsimulator": "AppleTVSimulator", "macosx": "MacOSX"}[sdk]]
    (resources / "Info.plist").write_bytes(plistlib.dumps(info))
    if mac:
        (framework / "Versions/Current").symlink_to("A")
        for name in ("Libbox", "Headers", "Resources", "Modules"):
            (framework / name).symlink_to("Versions/Current/" + name)

    install_name = "@rpath/Libbox.framework/" + ("Versions/A/" if mac else "") + "Libbox"
    binaries = []
    for arch in library["SupportedArchitectures"]:
        binary = framework.parent / arch
        target = f"{arch}-apple-{os_name}{minimum}" + ("-simulator" if simulator else "")
        command = ["xcrun", "--sdk", sdk, "clang", "-target", target, "-dynamiclib",
                   "-fapplication-extension", "-install_name", install_name, "-Wl,-x",
                   "-Xlinker", "-force_load", "-Xlinker", source / "Libbox",
                   "-framework", "Foundation", "-framework", "Security", "-framework", "Network",
                   "-lresolv", "-o", binary]
        if mac:
            command += ["-framework", "SystemConfiguration", "-framework", "IOKit"]
        subprocess.run(command, check=True)
        binaries.append(binary)
    subprocess.run(["xcrun", "lipo", "-create", *binaries, "-output", contents / "Libbox"], check=True)
    # Preserve crash symbolication outside the app. Strip the local debug map
    # (which names build-machine object paths) only after extracting the dSYM.
    symbols = framework.with_suffix(".framework.dSYM")
    subprocess.run(["xcrun", "dsymutil", contents / "Libbox", "-o", symbols], check=True)
    subprocess.run(["xcrun", "strip", "-S", "-x", contents / "Libbox"], check=True)
    return framework, symbols


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("static", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    source = args.static.resolve()
    output = args.output.resolve()
    libraries = plistlib.loads((source / "Info.plist").read_bytes())["AvailableLibraries"]
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent) as temporary:
        scratch = Path(temporary)
        command = ["xcodebuild", "-create-xcframework"]
        for library in libraries:
            framework, symbols = build_slice(source, library, scratch)
            command += ["-framework", framework, "-debug-symbols", symbols]
        product = scratch / output.name
        subprocess.run([*command, "-output", product], check=True)
        if output.exists():
            shutil.rmtree(output)
        product.rename(output)


if __name__ == "__main__":
    main()

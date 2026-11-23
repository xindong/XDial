#!/usr/bin/env python3
"""Verify the exact dyld paths of the host and network extension in an Apple build."""
import argparse
import plistlib
import subprocess
from pathlib import Path


def executable(bundle):
    contents = bundle / "Contents"
    if not contents.is_dir():
        contents = bundle
    metadata = plistlib.loads((contents / "Info.plist").read_bytes())
    folder = contents / "MacOS" if contents != bundle else bundle
    return folder / metadata["CFBundleExecutable"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    app = parser.parse_args().app
    frameworks = list(app.rglob("Libbox.framework"))
    if len(frameworks) != 1:
        raise SystemExit(f"Expected one embedded Libbox in {app}, found {frameworks}")
    library = (frameworks[0] / "Libbox").resolve(strict=True)
    mac = (app / "Contents").is_dir()
    expected = "@rpath/Libbox.framework/" + ("Versions/A/" if mac else "") + "Libbox"
    providers = [p for p in app.rglob("*.appex") if p.name.endswith(("Tunnel.appex", "Proxy.appex"))]
    if len(providers) != 1:
        raise SystemExit(f"Expected one network extension in {app}")
    for target in [app, *providers]:
        binary = executable(target)
        for arch in subprocess.check_output(["lipo", "-archs", binary], text=True).split():
            flags = ["otool", "-arch", arch]
            imports = subprocess.check_output([*flags, "-L", binary], text=True)
            if not any(row.strip().split()[0] == expected for row in imports.splitlines()[1:] if row.strip()):
                raise SystemExit(f"{binary.name} ({arch}) does not link {expected}")
            loads = subprocess.check_output([*flags, "-l", binary], text=True).splitlines()
            paths = [loads[i + 2].strip().split(" (offset")[0].removeprefix("path ")
                     for i, line in enumerate(loads) if line.strip() == "cmd LC_RPATH"]
            resolved = [(binary.parent / path.removeprefix("@executable_path/") / expected[7:]).resolve()
                        for path in paths if path.startswith("@executable_path/")]
            if library not in resolved:
                raise SystemExit(f"{binary.name} ({arch}) cannot resolve embedded Libbox: {paths}")
    print(f"{app.name}: host and extension resolve {expected}")


if __name__ == "__main__":
    main()

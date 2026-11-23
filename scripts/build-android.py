#!/usr/bin/env python3
"""Build, inspect and package Android test artifacts. Never uploads or installs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build/android"
BUILD_TOOLS = "36.0.0"
NDK = "27.1.12297006"
ABIS = ["arm64-v8a", "x86_64"]


def read_contract():
    return dict(line.split("=", 1) for line in (ROOT / "android/version.properties").read_text().splitlines()
                if line and not line.startswith("#"))


def version_code(contract, supplied, env):
    if supplied is not None:
        value = str(supplied)
    elif env.get("GITHUB_ACTIONS") == "true":
        run, attempt = env.get("GITHUB_RUN_NUMBER", ""), env.get("GITHUB_RUN_ATTEMPT", "")
        if not run.isdigit() or int(run) < 1 or not attempt.isdigit() or not 1 <= int(attempt) <= 99:
            raise ValueError("CI requires a positive run number and attempt between 1 and 99")
        value = str(int(contract["ciVersionCodeBase"]) + int(run) * 100 + int(attempt))
    else:
        value = contract["versionCode"]
    if not re.fullmatch(r"[1-9][0-9]*", value) or int(value) > 2100000000:
        raise ValueError("Android version code must be between 1 and 2100000000")
    return int(value)


def fingerprint(value):
    clean = value.replace(":", "").lower()
    if not re.fullmatch(r"[0-9a-f]{64}", clean):
        raise ValueError("A full signing certificate SHA-256 fingerprint is required")
    return clean


def output(command, env=None):
    return subprocess.check_output(command, cwd=ROOT, env=env, text=True, stderr=subprocess.PIPE).strip()


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def tool_environment():
    env = os.environ.copy()
    sdk, java = env.get("ANDROID_HOME"), env.get("JAVA_HOME")
    if not sdk or not java:
        raise ValueError("Set ANDROID_HOME and JAVA_HOME (JDK 17)")
    env["PATH"] = str(Path(java) / "bin") + os.pathsep + env.get("PATH", "")
    tools = Path(sdk) / "build-tools" / BUILD_TOOLS
    for name in ["aapt", "apksigner", "zipalign"]:
        if not (tools / name).is_file():
            raise ValueError("Install Android build-tools;" + BUILD_TOOLS)
    ndk = Path(sdk) / "ndk" / NDK
    if not (ndk / "source.properties").is_file() or not (Path(sdk) / "platforms/android-36/android.jar").is_file():
        raise ValueError("Install Android platform 36 and NDK " + NDK)
    env["ANDROID_NDK_HOME"] = str(ndk)
    env["ANDROID_GO_TARGET"] = "android/arm64,android/amd64"
    go = output(["go", "env", "GOVERSION"], env)
    expected_go = "go" + re.search(r"^go (.+)$", (ROOT / "go.mod").read_text(), re.M).group(1)
    if go != expected_go:
        raise ValueError("Use the Go version in go.mod: " + expected_go)
    java_version = subprocess.run([str(Path(java) / "bin/java"), "-version"], capture_output=True, text=True).stderr
    if not re.search(r'version "17[.\"]', java_version):
        raise ValueError("Use JDK 17 for the Android build")
    return env, tools, go, java_version.splitlines()[0]


def run_build(command, env, log):
    with log.open("w") as stream:
        result = subprocess.run(command, cwd=ROOT, env=env, stdout=stream, stderr=subprocess.STDOUT)
    if result.returncode:
        raise ValueError("Build failed; inspect " + str(log.relative_to(ROOT)))


def signing_inputs(env):
    names = ["XDIAL_ANDROID_KEYSTORE", "XDIAL_ANDROID_KEY_ALIAS", "XDIAL_ANDROID_STORE_PASSWORD",
             "XDIAL_ANDROID_KEY_PASSWORD", "XDIAL_ANDROID_CERT_SHA256"]
    if any(not env.get(name) for name in names):
        raise ValueError("Signed mode requires all five XDIAL_ANDROID signing variables; see docs/agent/android-release.md")
    key = Path(env[names[0]]).resolve()
    primary_repo = (ROOT / output(["git", "rev-parse", "--git-common-dir"])).resolve().parent
    if not key.is_file() or any(root == key or root in key.parents for root in [ROOT, primary_repo]):
        raise ValueError("The signing keystore must exist outside the repository")
    return key, fingerprint(env[names[-1]])


def sign_apk(source, target, tools, env):
    key, expected = signing_inputs(env)
    # Password values are inherited only by this signing process, never argv or
    # Gradle logs. A separate output preserves the inspected unsigned input.
    command = [str(tools / "apksigner"), "sign", "--ks", str(key), "--ks-key-alias", env["XDIAL_ANDROID_KEY_ALIAS"],
               "--ks-pass", "env:XDIAL_ANDROID_STORE_PASSWORD", "--key-pass", "env:XDIAL_ANDROID_KEY_PASSWORD",
               "--v4-signing-enabled", "false", "--out", str(target), str(source)]
    result = subprocess.run(command, env=env, capture_output=True)
    if result.returncode:
        raise ValueError("APK signing failed; check keystore, alias and passwords (signer output withheld)")
    return expected


def inspect_apk(apk, mode, code, name, tools, env, expected_cert=None, expected_abis=ABIS):
    with zipfile.ZipFile(apk) as archive:
        if archive.testzip() is not None:
            raise ValueError("APK ZIP integrity check failed")
        abis = sorted(item.split("/")[1] for item in archive.namelist()
                      if re.fullmatch(r"lib/[^/]+/libgojni.so", item))
    if abis != expected_abis:
        raise ValueError(f"Expected APK native architectures {expected_abis}, found {abis}")
    badging = output([str(tools / "aapt"), "dump", "badging", str(apk)], env)
    package = re.search(r"package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'", badging)
    app_id = "com.xd.xdial.android" + (".debug" if mode == "debug" else "")
    expected_name = name + ("-dev" if mode == "debug" else "")
    if not package or package.groups() != (app_id, str(code), expected_name):
        raise ValueError("APK identity/version does not match the requested build")
    if "sdkVersion:'26'" not in badging or "targetSdkVersion:'36'" not in badging:
        raise ValueError("APK SDK contract changed")
    if ("application-debuggable" in badging) != (mode == "debug"):
        raise ValueError("APK debuggable flag does not match its build mode")
    verify = subprocess.run([str(tools / "apksigner"), "verify", "--verbose", "--print-certs", str(apk)],
                            env=env, capture_output=True, text=True)
    certs = re.findall(r"Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F]+)", verify.stdout)
    if mode == "unsigned":
        if verify.returncode == 0 or certs:
            raise ValueError("Expected an unsigned release APK")
    elif verify.returncode or len(certs) != 1:
        raise ValueError("APK signature verification failed")
    elif expected_cert and fingerprint(certs[0]) != expected_cert:
        raise ValueError("APK signer does not match the pinned certificate")
    # AGP aligns before signing. Refuse a broken final file instead of fixing a
    # signed APK and accidentally invalidating its signature.
    if subprocess.run([str(tools / "zipalign"), "-c", "-P", "16", "4", str(apk)],
                      capture_output=True).returncode:
        raise ValueError("APK alignment verification failed")
    return {"application_id": app_id, "version_code": code, "version_name": expected_name,
            "min_sdk": 26, "target_sdk": 36, "abis": abis, "signing": mode,
            "certificate_sha256": certs[0].lower() if certs else None, "installable": mode != "unsigned"}


def package_artifact(apk, details, provenance):
    sha = digest(apk)
    abi = "-".join(details["abis"])
    stem = f"xdial-{details['version_code']}-{details['signing']}-{abi}-{sha[:12]}"
    destination = BUILD / "artifacts" / stem
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="package-", dir=BUILD) as temporary:
        staged = Path(temporary)
        filename = stem + ".apk"
        shutil.copyfile(apk, staged / filename)
        manifest = dict(provenance, **details, schema_version=1, apk=filename, sha256=sha,
                        distribution="local-artifact-only")
        (staged / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        (staged / "SHA256SUMS").write_text("{}  {}\n{}  manifest.json\n".format(sha, filename, digest(staged / "manifest.json")))
        # Identity includes provenance: an identical APK from another revision
        # cannot silently reuse the first build's manifest.
        destination = destination.with_name(stem + "-" + digest(staged / "manifest.json")[:12])
        if destination.exists():
            for item in staged.iterdir():
                if not (destination / item.name).is_file() or digest(destination / item.name) != digest(item):
                    raise ValueError("An existing artifact was changed; refusing to reuse it")
            return destination
        os.rename(staged, destination)
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["debug", "unsigned", "signed", "ci"], default="debug")
    parser.add_argument("--version-code")
    args = parser.parse_args()
    contract = read_contract()
    code = version_code(contract, args.version_code, os.environ)
    revision = output(["git", "rev-parse", "HEAD"])
    dirty = bool(output(["git", "status", "--porcelain", "--untracked-files=normal"]))
    env, tools, go, java = tool_environment()
    if args.mode == "signed":
        if dirty or (args.version_code is None and os.environ.get("GITHUB_ACTIONS") != "true"):
            raise ValueError("Signed test builds require a clean source revision and an explicit version code")
        if env.get("GITHUB_EVENT_NAME") == "pull_request":
            raise ValueError("Pull request builds may not use the test signing identity")
        signing_inputs(env)
    # Signing variables do not enter the build process/Gradle daemon.
    build_env = {key: value for key, value in env.items() if not key.startswith("XDIAL_ANDROID_")}
    build_env["XDIAL_ANDROID_VERSION_CODE"] = str(code)
    build_env["XDIAL_ANDROID_VERSION_NAME"] = contract["versionName"]
    BUILD.mkdir(parents=True, exist_ok=True)
    run_build(["bash", "scripts/check-public-content.sh"], build_env, BUILD / "package-gate.log")
    run_build(["bash", "scripts/build-android-core.sh"], build_env, BUILD / "package-core.log")
    modes = ["debug", "unsigned"] if args.mode == "ci" else [args.mode]
    gradle = [str(ROOT / "android/gradlew"), "-p", "android", "--no-daemon"]
    if "debug" in modes:
        run_build([*gradle, "assembleDebug"], build_env, BUILD / "package-debug.log")
    if any(mode != "debug" for mode in modes):
        run_build([*gradle, "-PxdialSplitApks=true", "assembleRelease", "bundleRelease"],
                  build_env, BUILD / "package-release.log")
    provenance = {"source_revision": revision, "source_dirty": dirty, "aar_sha256": digest(BUILD / "Libbox.aar"),
                  "toolchain": {"go": go, "java": java, "gradle": "9.4.1", "agp": "9.2.1", "ndk": NDK,
                                "build_tools": BUILD_TOOLS, "compile_sdk": 36}}
    for mode in modes:
        outputs = ROOT / "android/app/build/outputs/apk"
        variants = ([(outputs / "debug/app-debug.apk", ABIS)] if mode == "debug" else
                    [(outputs / f"release/app-{abi}-release-unsigned.apk", [abi]) for abi in ABIS])
        for source, abis in variants:
            with tempfile.TemporaryDirectory(prefix="sign-", dir=BUILD) as temporary:
                apk, expected = source, None
                if mode == "signed":
                    apk = Path(temporary) / "app-signed.apk"
                    expected = sign_apk(source, apk, tools, env)
                details = inspect_apk(apk, mode, code, contract["versionName"], tools, env, expected, abis)
                destination = package_artifact(apk, details, provenance)
                print(destination.relative_to(ROOT))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        # Commands may hold private filesystem paths. Do not dump subprocess
        # arguments, environments or captured signer stderr.
        print("Android packaging failed: " + (str(error) if isinstance(error, ValueError) else type(error).__name__), file=sys.stderr)
        sys.exit(1)

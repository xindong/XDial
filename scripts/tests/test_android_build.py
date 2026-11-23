import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("android_build", Path(__file__).resolve().parents[1] / "build-android.py")
build = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build)


class VersionContract(unittest.TestCase):
    def test_ci_attempts_and_runs_are_monotonic(self):
        contract = build.read_contract()
        codes = [build.version_code(contract, None, dict(GITHUB_ACTIONS="true", GITHUB_RUN_NUMBER=str(run), GITHUB_RUN_ATTEMPT=str(attempt)))
                 for run, attempt in [(1, 1), (1, 2), (1, 99), (2, 1)]]
        self.assertEqual(codes, sorted(set(codes)))
        self.assertEqual(build.version_code(contract, "42", {}), 42)

    def test_invalid_or_exhausted_codes_are_rejected(self):
        for value in ["0", "-1", "1.2", "001", "2100000001"]:
            with self.assertRaises(ValueError):
                build.version_code(build.read_contract(), value, {})
        for run, attempt in [("1", "100"), ("1", "0"), ("", "1"), ("21000000", "1")]:
            with self.assertRaises(ValueError):
                build.version_code(build.read_contract(), None, dict(GITHUB_ACTIONS="true", GITHUB_RUN_NUMBER=run, GITHUB_RUN_ATTEMPT=attempt))

    def test_certificate_is_pinned_not_a_short_prefix(self):
        self.assertEqual(build.fingerprint(":".join(["AB"] * 32)), "ab" * 32)
        for invalid in ["", "ab" * 31, "zz" * 32]:
            with self.assertRaises(ValueError):
                build.fingerprint(invalid)

    def test_artifacts_are_immutable_and_keep_source_provenance(self):
        # Packaging alone is isolated here. Real APK parsing/signing is below.
        with tempfile.TemporaryDirectory() as tmp, patch.object(build, "BUILD", Path(tmp)):
            source = Path(tmp) / "input.apk"
            source.write_bytes(b"non-APK packaging fixture")
            details = dict(version_code=1, signing="unsigned", abis=["arm64-v8a"])
            first = build.package_artifact(source, details, dict(source_revision="a" * 40))
            second = build.package_artifact(source, details, dict(source_revision="b" * 40))
            self.assertNotEqual(first, second)
            self.assertEqual(first, build.package_artifact(source, details, dict(source_revision="a" * 40)))
            next(first.glob("*.apk")).write_bytes(b"tampered fixture")
            with self.assertRaises(ValueError):
                build.package_artifact(source, details, dict(source_revision="a" * 40))


@unittest.skipUnless(os.environ.get("XDIAL_ANDROID_TEST_APK"), "Set XDIAL_ANDROID_TEST_APK to test the real unsigned APK")
class RealSigningContract(unittest.TestCase):
    def test_real_signer_pinned_certificate_and_tamper_rejection(self):
        env, tools, _, _ = build.tool_environment()
        source = Path(os.environ["XDIAL_ANDROID_TEST_APK"]).resolve()
        abi = os.environ["XDIAL_ANDROID_TEST_ABI"]
        code = build.version_code(build.read_contract(), os.environ.get("XDIAL_ANDROID_TEST_CODE"), os.environ)
        name = build.read_contract()["versionName"]
        build.inspect_apk(source, "unsigned", code, name, tools, env, expected_abis=[abi])
        # Disposable certificate solely for signing-contract acceptance. It is
        # not the XDial test channel identity and no signed fixture is published.
        with tempfile.TemporaryDirectory(prefix="xdial-signing-fixture-") as tmp:
            key = Path(tmp) / "fixture.p12"
            env.update(XDIAL_ANDROID_KEYSTORE=str(key), XDIAL_ANDROID_KEY_ALIAS="fixture",
                       XDIAL_ANDROID_STORE_PASSWORD="disposable-test-only", XDIAL_ANDROID_KEY_PASSWORD="disposable-test-only")
            result = subprocess.run([str(Path(env["JAVA_HOME"]) / "bin/keytool"), "-genkeypair", "-noprompt",
                                     "-keystore", str(key), "-storetype", "PKCS12", "-alias", "fixture",
                                     "-storepass:env", "XDIAL_ANDROID_STORE_PASSWORD", "-keypass:env", "XDIAL_ANDROID_KEY_PASSWORD",
                                     "-dname", "CN=XDial disposable test fixture", "-keyalg", "RSA", "-keysize", "2048", "-validity", "1"],
                                    env=env, capture_output=True)
            self.assertEqual(result.returncode, 0, "fixture certificate creation failed")
            certificate = subprocess.check_output([str(Path(env["JAVA_HOME"]) / "bin/keytool"), "-exportcert", "-keystore", str(key),
                                                   "-alias", "fixture", "-storepass:env", "XDIAL_ANDROID_STORE_PASSWORD"], env=env, stderr=subprocess.PIPE)
            env["XDIAL_ANDROID_CERT_SHA256"] = build.hashlib.sha256(certificate).hexdigest()
            target = Path(tmp) / "signed.apk"
            expected = build.sign_apk(source, target, tools, env)
            build.inspect_apk(target, "signed", code, name, tools, env, expected, [abi])
            with self.assertRaisesRegex(ValueError, "pinned certificate"):
                build.inspect_apk(target, "signed", code, name, tools, env, "0" * 64, [abi])
            with target.open("r+b") as stream:
                stream.seek(64)
                original = stream.read(1)
                stream.seek(64)
                stream.write(bytes([original[0] ^ 1]))
            result = subprocess.run([str(tools / "apksigner"), "verify", str(target)], env=env, capture_output=True)
            self.assertNotEqual(result.returncode, 0, "modified APK still verified")

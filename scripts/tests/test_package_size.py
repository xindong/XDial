import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("package_size", ROOT / "scripts/package-size.py")
sizes = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sizes)


class PackageSizeContract(unittest.TestCase):
    def test_missing_empty_and_file_apps_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "Test.app"
            with self.assertRaises(ValueError):
                sizes.measure(app)
            app.write_bytes(b"not a directory")
            with self.assertRaises(ValueError):
                sizes.measure(app)
            app.unlink()
            app.mkdir()
            with self.assertRaises(ValueError):
                sizes.measure(app)
            (app / "binary").write_bytes(b"12345")
            self.assertEqual(sizes.measure(app)["payload"], 5)

    def test_optional_baseline_failures_still_measure_current_product(self):
        # Execute the actual composite action's shell with a failing gh. A
        # partial download must not become a successful comparison baseline.
        action = (ROOT / ".github/actions/package-size/action.yml").read_text()
        script = action.split("      run: |\n", 1)[1].split("    - uses:", 1)[0]
        script = "\n".join(line[8:] for line in script.splitlines())
        for failure in ("lookup", "download"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                (root / "scripts").mkdir()
                (root / "scripts/package-size.py").symlink_to(ROOT / "scripts/package-size.py")
                with ZipFile(root / "current.apk", "w") as archive:
                    archive.writestr("binary", b"12345")
                gh = root / "gh"
                gh.write_text('#!/bin/bash\nif [[ "$2" == list ]]; then\n'
                              '  [[ "$FAILURE" == lookup ]] && exit 1\n'
                              '  echo 123; exit 0\nfi\n'
                              'mkdir -p build/size-reports/test/base\n'
                              'echo invalid > build/size-reports/test/base/report.json\nexit 1\n')
                gh.chmod(0o755)
                env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
                           FAILURE=failure, SIZE_GROUP="test", PRODUCTS="current.apk",
                           BASE_SHA="a" * 40, GITHUB_STEP_SUMMARY=str(root / "summary"))
                result = subprocess.run(["bash", "-c", script], cwd=root, env=env,
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                report = json.loads((root / "build/size-reports/test/report.json").read_text())
                self.assertEqual(report["current.apk"]["payload"], 5)
                self.assertIn("base report unavailable", (root / "summary").read_text())

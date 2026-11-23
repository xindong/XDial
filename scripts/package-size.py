#!/usr/bin/env python3
"""Compare unsigned build products in CI. All measurements use decimal bytes."""
import argparse
import json
import tarfile
import tempfile
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED


def measure(path):
    if path.suffix == ".app":
        if not path.is_dir():
            raise ValueError(f"App directory does not exist: {path}")
        files = {p.relative_to(path).as_posix(): p for p in path.rglob("*")
                 if not p.is_symlink() and p.is_file()}
        if not files:
            raise ValueError(f"App contains no files: {path}")
        # An unencrypted ZIP estimate reproducible on CI. App Store thinning,
        # encryption, receipts and file-system allocation are measured by ASC.
        with tempfile.TemporaryFile() as temp:
            with ZipFile(temp, "w", ZIP_DEFLATED) as archive:
                for name, file in sorted(files.items()):
                    archive.write(file, name)
            package = temp.tell()
        entries = [(name, file.stat().st_size) for name, file in files.items()]
    elif path.name.endswith(".tar.gz"):
        with tarfile.open(path) as archive:
            entries = [(member.name, member.size) for member in archive if member.isfile()]
        package = path.stat().st_size
    else:
        with ZipFile(path) as archive:
            entries = [(entry.filename, entry.file_size) for entry in archive.infolist() if not entry.is_dir()]
        package = path.stat().st_size
    return dict(package=package, payload=sum(size for _, size in entries),
                largest=sorted(entries, key=lambda entry: -entry[1])[:3])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("products", nargs="+", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline", type=Path)
    args = parser.parse_args()
    baseline = json.loads(args.baseline.read_text()) if args.baseline and args.baseline.exists() else {}
    results = {}
    print("| Build product | Package MB | Payload MB | Largest files (MB) |")
    print("| --- | ---: | ---: | --- |")
    for path in args.products:
        name = path.name
        if name in results:
            parser.error(f"Duplicate product name: {name}")
        result = results[name] = measure(path)
        sizes = []
        for key in ("package", "payload"):
            size = result[key] / 1e6
            delta = (size - baseline[name][key] / 1e6) if name in baseline else None
            sizes.append(f"{size:.2f}" + (f" ({delta:+.2f})" if delta is not None else ""))
        largest = ", ".join(f"{Path(file).name} ({n / 1e6:.2f})" for file, n in result["largest"])
        print(f"| {name} | {sizes[0]} | {sizes[1]} | {largest} |")
    print("\nPackage is the distribution file or a ZIP estimate for an Apple .app. "
          "Payload is the logical file total before compression. Store device sizes may differ.")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()

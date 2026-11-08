#!/usr/bin/env python3
"""Run routing contracts with SHA-verified, frozen official BookOrbit methods.

Downloaded source stays in ignored test-results, never in runtime ZIPs. These
are headless contracts: real download/bulk/sheet/path-check methods, mocked
network, filesystem, widgets and transfer execution. Not physical-device QA.
"""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
# These four files are byte-identical in the two reviewed server tags.
FILES = {
    "bookorbit_catalog_download.lua": "3c3e0869de176073d7e533ed70c41ce88b87b4a4702e918ac957474fe74e1c52",
    "bookorbit_catalog_bulk_download.lua": "ddf7e4c64d3fcef4b130b4a0e07580dcd2386063756c0aac18e1e7ca01638ca9",
    "bookorbit_download_sheet.lua": "60b7a93dc0143665cb7c543a945c1d737c5f2b2b05ced1f0c410bc9ec9e82a09",
    "bookorbit_download_transfer.lua": "9060030c2c6ba0b2dde0da6babbb586c4f3b5e328c1229175b4ed5775ad75346",
}
PINS = (
    ("minimum", "a96ff0c85a4c25e9126dfa4c71ea87537a3baf7a", "2.1.0"),  # v3.6.0
    ("current", "6f8f5f4818eb737dc4d78fc5b5294fc3adb26860", "2.2.0"),  # v3.7.0
)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--lua", default="luajit")
    args = parser.parse_args()
    for label, revision, version in PINS:
        target = ROOT / "test-results" / "bookorbit-routing" / ("native-" + label)
        target.mkdir(parents=True, exist_ok=True)
        for name, digest in FILES.items():
            path = target / name
            if not path.exists():
                url = f"https://raw.githubusercontent.com/bookorbit/bookorbit/{revision}/koreader-plugin/bookorbit.koplugin/{name}"
                with urllib.request.urlopen(url, timeout=30) as response:
                    content = response.read(1024 * 1024)
                if hashlib.sha256(content).hexdigest() != digest:
                    raise RuntimeError(f"Unexpected BookOrbit source: {revision}/{name}")
                path.write_bytes(content)
            if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
                raise RuntimeError(f"Cached BookOrbit source changed: {path}")
        env = dict(os.environ, BOOKORBIT_NATIVE_DIR=str(target), BOOKORBIT_PLUGIN_VERSION=version)
        print(f"Frozen BookOrbit {revision}, plugin {version}, {args.lua}", flush=True)
        subprocess.run([args.lua, "tests/bookorbit_routing_spec.lua"], cwd=ROOT, env=env, check=True)


if __name__ == "__main__":
    main()

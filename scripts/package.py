#!/usr/bin/env python3
"""Build canonical and legacy runtime ZIPs without settings or development files."""
import hashlib
from pathlib import Path
import re
import zipfile

ROOT = Path(__file__).resolve().parents[1]
FILES = [
    "_meta.lua", "main.lua", "grimmory_updater.lua", "README.md", "INSTALL.md", "DEBUG.md",
    "LICENSE", "examples/path_rules.lua", "providers/init.lua",
    "providers/bookorbit.lua", "providers/grimmory.lua",
]
version = re.search(r'version = "([^"]+)"', (ROOT / "_meta.lua").read_text()).group(1)
output = ROOT / "dist"
output.mkdir(exist_ok=True)
for plugin in ("library-sync.koplugin", "grimmory-sync.koplugin"):
    archive = output / (plugin + ".zip")
    prefix = plugin + "/"
    directories = {prefix}
    directories.update(prefix + str(Path(name).parent) + "/" for name in FILES if "/" in name)
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as bundle:
        for name in sorted(directories):
            entry = zipfile.ZipInfo(name)
            entry.create_system = 3
            entry.external_attr = (0o40755 << 16) | 0x10
            bundle.writestr(entry, b"")
        for name in sorted(FILES):
            path = ROOT / name
            assert path.is_file() and not path.is_symlink(), name
            entry = zipfile.ZipInfo(prefix + name)
            entry.create_system = 3
            entry.external_attr = 0o100644 << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            bundle.writestr(entry, path.read_bytes())
    with zipfile.ZipFile(archive) as bundle:
        assert bundle.testzip() is None
        assert set(bundle.namelist()) == directories | {prefix + name for name in FILES}
    checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
    archive.with_suffix(".zip.sha256").write_text(f"{checksum}  {archive.name}\n")
    print(f"{version}: {archive.name} ({archive.stat().st_size} bytes), SHA-256 {checksum}")

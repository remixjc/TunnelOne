#!/usr/bin/env python3
"""Create a complete source distribution for the bundled components."""
import io
import os
import pathlib
import subprocess
import tarfile
import urllib.request
from prepare import ROOT, LOCK, download, ensure_go

destination = ROOT / "dist"
destination.mkdir(exist_ok=True)
version = (ROOT / "VERSION").read_text().strip()
vendor = download("vendor.tar.gz", LOCK["assets"]["vendor.tar.gz"])
source_url = f"https://codeload.github.com/MetaCubeX/mihomo/tar.gz/{LOCK['mihomoRevision']}"
cache = ROOT / ".cache/downloads" / f"mihomo-{LOCK['mihomoRevision']}.tar.gz"
if not cache.exists():
    request = urllib.request.Request(source_url, headers={"User-Agent": "TunnelOne-build"})
    with urllib.request.urlopen(request, timeout=120) as response, cache.open("wb") as output:
        import shutil
        shutil.copyfileobj(response, output)

environment = dict(os.environ)
go = str(ensure_go())
modules = []
for directory in ["CoreLauncher", "Sources/WireGuardKitGo"]:
    subprocess.run([go, "mod", "download"], cwd=ROOT / directory, env=environment, check=True)
    output = subprocess.check_output([go, "list", "-m", "-json", "all"],
                                     cwd=ROOT / directory, env=environment, text=True)
    import json
    decoder = json.JSONDecoder()
    while output.strip():
        item, index = decoder.raw_decode(output.lstrip())
        output = output.lstrip()[index:]
        if not item.get("Main") and item.get("Dir"):
            modules.append((item["Path"] + "@" + item["Version"], pathlib.Path(item["Dir"])))

archive = destination / f"TunnelOne-{version}-corresponding-source.tar.gz"
with tarfile.open(archive, "w:gz") as target:
    # Only tracked files; no local profiles, certificates, caches or binaries.
    files = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).split(b"\0")
    for filename in files:
        if filename:
            path = ROOT / os.fsdecode(filename)
            if path.is_file():
                target.add(path, arcname="TunnelOne/" + os.fsdecode(filename), recursive=False)
    target.add(cache, arcname=f"upstream/mihomo-{LOCK['mihomoRevision']}.tar.gz")
    target.add(vendor, arcname="upstream/mihomo-vendor.tar.gz")
    seen = set()
    for module, path in modules:
        if module not in seen:
            seen.add(module)
            target.add(path, arcname="go-modules/" + module)
    manifest = (
        f"TunnelOne {version}\nMihomo {LOCK['mihomoVersion']} {LOCK['mihomoRevision']}\n"
        "See TunnelOne/docs/third-party.md for rebuild instructions and component licenses.\n"
    ).encode()
    info = tarfile.TarInfo("SOURCE-MANIFEST.txt")
    info.size = len(manifest)
    info.mode = 0o644
    target.addfile(info, io.BytesIO(manifest))
print(archive.name)

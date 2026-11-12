#!/usr/bin/env python3
"""Fetch pinned dependencies, verify SHA-256, and build the universal proxy runtime."""
import argparse
import concurrent.futures
import gzip
import hashlib
import json
import os
import pathlib
import platform
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
LOCK = json.loads((ROOT / "scripts/dependencies.lock.json").read_text())
CACHE = ROOT / ".cache/downloads"


def download(name, metadata):
    CACHE.mkdir(parents=True, exist_ok=True)
    path = CACHE / name
    expected = metadata["sha256"]
    if not expected or len(expected) != 64:
        raise RuntimeError(f"Missing SHA-256 for {name}")
    if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() == expected:
        return path
    print(f"Downloading {name}", flush=True)
    temporary = path.with_suffix(path.suffix + ".partial")
    request = urllib.request.Request(metadata["url"], headers={"User-Agent": "TunnelOne-build"})
    with urllib.request.urlopen(request, timeout=120) as response, temporary.open("wb") as output:
        shutil.copyfileobj(response, output)
    actual = hashlib.sha256(temporary.read_bytes()).hexdigest()
    if actual != expected:
        temporary.unlink(missing_ok=True)
        raise RuntimeError(f"SHA-256 mismatch for {name}")
    temporary.replace(path)
    return path


def ensure_go():
    target = ROOT / ".tools/go/bin/go"
    if target.exists():
        version = subprocess.check_output([target, "version"], text=True)
        if "go" + LOCK["goVersion"] in version:
            return target
        raise RuntimeError("Unexpected local Go version; remove .tools/go and retry")
    architecture = "arm64" if platform.machine() == "arm64" else "amd64"
    archive = download(f"go{LOCK['goVersion']}.darwin-{architecture}.tar.gz", LOCK["go"][architecture])
    destination = ROOT / ".tools"
    destination.mkdir(exist_ok=True)
    with tarfile.open(archive) as source:
        for member in source.getmembers():
            if member.name.startswith("/") or ".." in pathlib.PurePosixPath(member.name).parts:
                raise RuntimeError("Unsafe archive member")
        source.extractall(destination, filter="data")
    return target


def prepare():
    go = ensure_go()
    destination = ROOT / "build/core"
    destination.mkdir(parents=True, exist_ok=True)
    names = [name for name in LOCK["assets"] if name.startswith("mihomo-")]
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        archives = list(pool.map(lambda name: download(name, LOCK["assets"][name]), names))
    parts = []
    for archive in archives:
        name = "arm64" if "arm64" in archive.name else "x86_64"
        part = destination / f"mihomo-{name}"
        with gzip.open(archive, "rb") as source, part.open("wb") as output:
            shutil.copyfileobj(source, output)
        part.chmod(0o755)
        parts.append(str(part))
    subprocess.run(["lipo", "-create", *parts, "-output", str(destination / "mihomo")], check=True)
    launcher_parts = []
    for goarch, architecture in [("arm64", "arm64"), ("amd64", "x86_64")]:
        part = destination / f"launcher-{architecture}"
        environment = dict(os.environ, GOOS="darwin", GOARCH=goarch, CGO_ENABLED="0")
        subprocess.run([str(go), "build", "-trimpath", "-ldflags=-s -w", "-o", str(part), "."],
                       cwd=ROOT / "CoreLauncher", env=environment, check=True)
        launcher_parts.append(str(part))
    subprocess.run(["lipo", "-create", *launcher_parts, "-output",
                    str(destination / "tunnelone-core-launcher")], check=True)
    print("Universal proxy runtime ready.", flush=True)


if __name__ == "__main__":
    argparse.ArgumentParser(description=__doc__).parse_args()
    prepare()

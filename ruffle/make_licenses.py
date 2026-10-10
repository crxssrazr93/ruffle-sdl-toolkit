#!/usr/bin/env python3
"""make_licenses.py <ruffle-src> <out file>

Writes LICENSE.ruffle.txt for the shipped ruffle_sdl: Ruffle's own license (top of its LICENSE.md),
a table of every crate linked into ruffle_sdl for the target (normal dependencies with ruffle_sdl's own
features, without proc-macros and build-time crates), and the license files those crates ship (each
distinct text once, with the crates that use it).
Needs cargo. TARGET env overrides the target triple (default aarch64-unknown-linux-gnu).
"""
import collections
import hashlib
import json
import os
import subprocess
import sys

if len(sys.argv) != 3:
    sys.exit("usage: make_licenses.py <ruffle-src> <out file>")
src, out = sys.argv[1], sys.argv[2]
target = os.environ.get("TARGET", "aarch64-unknown-linux-gnu")
meta = json.loads(subprocess.run(
    ["cargo", "metadata", "--format-version", "1", "--filter-platform", target,
     "--manifest-path", f"{src}/sdl/Cargo.toml"],
    check=True, capture_output=True, text=True).stdout)
# cargo metadata unifies features across the whole workspace (desktop's TLS, egui, fonts, ...);
# cargo tree resolves ruffle_sdl alone, as cargo build -p ruffle_sdl does.
tree = subprocess.run(
    ["cargo", "tree", "-p", "ruffle_sdl", "--features", "lzma", "--target", target,
     "-e", "normal,no-proc-macro", "--prefix", "none", "-f", "{p}",
     "--manifest-path", f"{src}/Cargo.toml"],
    check=True, capture_output=True, text=True).stdout
linked = set()
for line in tree.splitlines():
    name, version = line.split()[:2]
    # "(/path)" marks a workspace crate (a registry crate of the same name and version can exist)
    linked.add((name, version.lstrip("v"), "(/" in line))

pkgs = {p["id"]: p for p in meta["packages"]}
seen = {i for i, p in pkgs.items() if (p["name"], p["version"], p["source"] is None) in linked}

own = [pkgs[i] for i in seen if pkgs[i]["source"] is None]  # Ruffle's workspace crates
third = sorted((pkgs[i] for i in seen if pkgs[i]["source"] is not None),
               key=lambda p: (p["name"], p["version"]))

ruffle_license = open(f"{src}/LICENSE.md", encoding="utf-8").read()
ruffle_license = ruffle_license.split("# Third-Party Libraries")[0].rstrip()

texts = collections.OrderedDict()  # hash -> (text, [crates])
for p in third:
    d = os.path.dirname(p["manifest_path"])
    files = sorted(f for f in os.listdir(d)
                   if f.upper().startswith(("LICENSE", "LICENCE", "COPYING", "COPYRIGHT", "NOTICE"))
                   and os.path.isfile(os.path.join(d, f)))
    for f in files:
        t = open(os.path.join(d, f), encoding="utf-8", errors="replace").read().strip()
        h = hashlib.sha1(t.encode()).hexdigest()
        texts.setdefault(h, (t, []))[1].append(f"{p['name']} {p['version']} ({f})")
    if not files:
        texts.setdefault("none:" + p["name"], (
            f"(no license file in the crate; its manifest says: {p['license']})", []))[1].append(
            f"{p['name']} {p['version']}")

with open(out, "w", encoding="utf-8", newline="\n") as o:
    o.write("ruffle_sdl: Ruffle (https://ruffle.rs) with the ruffle-sdl-toolkit patches and SDL2 front end.\n")
    o.write("The patches and the front end are under Ruffle's license below.\n\n")
    o.write(ruffle_license + "\n\n")
    o.write("# Third-party libraries linked into ruffle_sdl\n\n")
    o.write("| Crate | Version | License | Repository |\n|-|-|-|-|\n")
    for p in third:
        o.write(f"| {p['name']} | {p['version']} | {p['license'] or p.get('license_file')} | "
                f"{p['repository'] or ''} |\n")
    o.write("\n# License texts of the third-party libraries\n")
    for t, users in texts.values():
        o.write("\n" + "=" * 78 + "\nUsed by: " + ", ".join(users) + "\n" + "=" * 78 + "\n\n" + t + "\n")
print(f"{len(third)} crates, {len(texts)} distinct license texts, {len(own)} Ruffle crates")

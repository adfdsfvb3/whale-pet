#!/usr/bin/env python3
"""Materialize pnpm-deploy symlinks that escape the runtime dir.

`pnpm deploy --legacy` leaves two kinds of bad links in node_modules:
- root links like node_modules/@deepseek-ai/schemastery that resolve (via ../..)
  back into the source checkout — and break as soon as the tree is moved to a
  different absolute depth;
- deep .pnpm links with a wrong up-count that are broken even on the build
  machine and only worked via root-fallback resolution.

Both are replaced with real copies so the tree is self-contained. Canonical
package content is looked up in the deployed root node_modules first, then in
the source workspace (vendor/*, packages/*/*, native/landlock-run/packages/*).

Usage: materialize-links.py <node_modules> [workspace-root ...]
Exit 1 if unresolvable links remain (linux-only optional addons excluded).
"""
import json
import os
import shutil
import sys

root = os.path.realpath(sys.argv[1])
workspace = [os.path.realpath(p) for p in sys.argv[2:]]

# Linux-only optional natives are never resolved on macOS/Windows bundles.
OPTIONAL_PREFIXES = ("@deepseek-ai/node-addon-landlock-run-linux-",)

# Index workspace packages by name → directory (built lib/ included).
sources: dict[str, str] = {}
for ws in workspace:
    for pattern in ("vendor", "packages", "native/landlock-run/packages"):
        base = os.path.join(ws, pattern)
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if d != "node_modules"]
            if "package.json" not in filenames:
                continue
            try:
                name = json.load(open(os.path.join(dirpath, "package.json")))["name"]
            except (KeyError, json.JSONDecodeError):
                continue
            sources.setdefault(name, dirpath)
            dirnames[:] = ()


def pkg_key(link: str) -> str | None:
    base = os.path.basename(link)
    parent = os.path.basename(os.path.dirname(link))
    if parent == "node_modules":
        return base
    if parent.startswith("@"):
        return parent + "/" + base
    return None


def canonical(pkg: str) -> str | None:
    p = os.path.join(root, pkg)
    if os.path.exists(p):
        rp = os.path.realpath(p)
        if rp.startswith(root + os.sep):
            return rp
    return sources.get(pkg)


def materialize(link: str, src: str) -> None:
    os.remove(link)
    shutil.copytree(src, link, symlinks=True,
                    ignore=shutil.ignore_patterns("node_modules"))


fixed = 0
skipped: list[str] = []
links = [os.path.join(dp, f) for dp, _, fns in os.walk(root) for f in fns
         if os.path.islink(os.path.join(dp, f))]
for link in links:
    target = os.path.normpath(os.path.join(os.path.dirname(link), os.readlink(link)))
    if not os.path.exists(target) or not target.startswith(root + os.sep):
        key = pkg_key(link)
        src = canonical(key) if key else None
        if src and os.path.realpath(link) != src:
            materialize(link, src)
            fixed += 1
        elif key and key.startswith(OPTIONAL_PREFIXES):
            os.remove(link)  # dead weight on this platform
        elif key:
            skipped.append(link)

print(f"materialized {fixed} links")
for link in skipped:
    print(f"SKIP (no source): {link}", file=sys.stderr)
sys.exit(1 if skipped else 0)

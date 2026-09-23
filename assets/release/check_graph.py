#!/usr/bin/env python3
"""Check the Hiqlite part of a resolved dependency graph, from a Cargo.lock.

Usage:
    check_graph.py Cargo.lock            refuse unless the graph is releasable
    check_graph.py --report Cargo.lock   print whether it is, exit 0 either way
    check_graph.py --table Cargo.lock    print the resolved packages as a Markdown table
    check_graph.py --structure Cargo.lock
                                         refuse only on the shape of the graph (a second copy,
                                         an upstream package), not on where it resolves from

Releasable means exactly one copy of each patched Hiqlite package, every one of them from the
crates.io registry, none of upstream's own `hiqlite*` packages anywhere in the graph, and a single
`openraft`. A second copy of any of these would compile and would split the storage types or the
consensus implementation between two versions without anything saying so.

One file for both workflows, so that the candidate and the publish run cannot disagree about what
counts as the release graph.
"""

import re
import sys

PATCHED = ("hiqlite-patched", "hiqlite-wal-patched", "hiqlite-derive-patched")
REGISTRY = "registry+https://github.com/rust-lang/crates.io-index"


def packages(lock_path):
    out = []
    for block in open(lock_path).read().split("[[package]]"):
        name = re.search(r'^name = "([^"]+)"', block, re.M)
        if not name:
            continue
        version = re.search(r'^version = "([^"]+)"', block, re.M)
        source = re.search(r'^source = "([^"]+)"', block, re.M)
        checksum = re.search(r'^checksum = "([^"]+)"', block, re.M)
        out.append({
            "name": name.group(1),
            "version": version.group(1) if version else None,
            "source": source.group(1) if source else None,
            "checksum": checksum.group(1) if checksum else None,
        })
    return out


def problems(pkgs, structure_only=False):
    found = []
    hiq = [p for p in pkgs if p["name"].startswith("hiqlite")]
    for p in hiq:
        if p["name"] not in PATCHED:
            found.append(f"{p['name']} {p['version']} is not one of the patched packages")
        if structure_only:
            continue
        if p["source"] != REGISTRY:
            found.append(f"{p['name']} {p['version']} resolves to {p['source'] or 'a path'}")
        if not p["checksum"]:
            found.append(f"{p['name']} {p['version']} has no registry checksum")
    for name in PATCHED:
        copies = [p for p in hiq if p["name"] == name]
        if len(copies) != 1:
            found.append(f"{name}: {len(copies)} copies in the graph, expected exactly 1")
    raft = [p for p in pkgs if p["name"] == "openraft"]
    if len(raft) != 1:
        found.append(f"openraft: {len(raft)} copies in the graph, expected exactly 1")
    return found


def main(argv):
    mode = "check"
    if argv and argv[0] in ("--report", "--table", "--structure"):
        mode = argv.pop(0)[2:]
    if len(argv) != 1:
        sys.exit(__doc__)
    pkgs = packages(argv[0])

    if mode == "table":
        print("| Package | Version | Source | Checksum |")
        print("|---|---|---|---|")
        for p in pkgs:
            if p["name"].startswith("hiqlite") or p["name"] == "openraft":
                src = f"`{p['source']}`" if p["source"] else "**path, not a registry**"
                print(f"| `{p['name']}` | `{p['version']}` | {src} | `{p['checksum']}` |")
        return 0

    found = problems(pkgs, structure_only=(mode == "structure"))
    if mode == "report":
        print("true" if not found else "false")
        for f in found:
            print(f"  - {f}", file=sys.stderr)
        return 0
    if found:
        print("the dependency graph is not a release graph:", file=sys.stderr)
        for f in found:
            print(f"  - {f}", file=sys.stderr)
        return 1
    names = ", ".join(f"{p['name']} {p['version']}" for p in pkgs if p["name"] in PATCHED)
    if mode == "structure":
        print(f"graph shape: {names}, one openraft, no upstream hiqlite package")
    else:
        print(f"release graph: {names}, one openraft, all from crates.io")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

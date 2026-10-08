#!/usr/bin/env python3
"""
Build a clean zip of the mod for another PC: exactly the committed files of a git revision
(default: the current commit), without the dev/ test kit.

    python dev/package.py [revision] [--out folder]

The zip unpacks to an x4_coop/ folder; put it in "X4 Foundations/extensions/". Its name carries the
commit id, so both players can see they run the same version.
"""
import argparse
import subprocess
import sys
from pathlib import Path

MOD = Path(__file__).resolve().parent.parent


def git(*args):
    return subprocess.run(["git", "-C", str(MOD), *args], check=True, capture_output=True, text=True).stdout.strip()


def main(argv=None):
    p = argparse.ArgumentParser(description="Zip the mod for another PC")
    p.add_argument("revision", nargs="?", default="HEAD", help="git revision (default HEAD)")
    p.add_argument("--out", default=str(Path.home() / "Desktop"), help="folder for the zip (default: Desktop)")
    args = p.parse_args(argv)

    commit = git("rev-parse", "--short", args.revision)
    if args.revision == "HEAD" and git("status", "--porcelain", "--", ".", ":!dev"):
        print("note: there are uncommitted changes; the zip holds the last commit, not them")
    out = Path(args.out) / f"x4_coop-{commit}.zip"
    out.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "-C", str(MOD), "archive", "--format=zip", "--prefix=x4_coop/", "-o", str(out), commit,
                    "--", ".", ":!dev", ":!.gitattributes", ":!.gitignore"], check=True)
    print(f"{out}  ({out.stat().st_size / 1024:.0f} KB, commit {commit}: {git('log', '-1', '--format=%s', commit)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())

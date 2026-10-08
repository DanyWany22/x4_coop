"""
Extract files from X4's .cat/.dat archives (later archives override earlier ones).

    python catx.py <out_dir> <path regex> <cat files...>
    python catx.py out "^(libraries/.*\\.xsd|md/.*\\.xml)$" ../../../0*.cat

A .cat is a text index of "path size timestamp md5" lines; the .dat is the files back to back.
"""
import os
import re
import sys


def extract(out_dir, pattern, cats):
    rx = re.compile(pattern)
    count = 0
    for cat in cats:
        offset = 0
        with open(cat, encoding="utf-8", errors="replace") as index, open(cat[:-4] + ".dat", "rb") as data:
            for line in index:
                parts = line.rstrip("\r\n").rsplit(" ", 3)
                if len(parts) != 4:
                    continue
                path, size = parts[0], int(parts[1])
                if rx.search(path):
                    data.seek(offset)
                    dst = os.path.join(out_dir, path)
                    os.makedirs(os.path.dirname(dst), exist_ok=True)
                    with open(dst, "wb") as out:
                        out.write(data.read(size))
                    count += 1
                offset += size
    return count


if __name__ == "__main__":
    print("extracted", extract(sys.argv[1], sys.argv[2], sys.argv[3:]))

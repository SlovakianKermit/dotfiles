#!/usr/bin/env python3
import os
import sys
import time
import json
import sqlite3
import subprocess
import urllib.parse

BASE = "/home/killian/Downloads/Persepolis"
SUBDIRS = ["", "Videos", "Compressed", "Audios", "Documents", "Others"]
DB = "/home/killian/.config/persepolis_download_manager/persepolis.db"
MARK = '"; filename*=UTF-8\'\''


def clean_name(fn):
    if MARK not in fn:
        return None
    return urllib.parse.unquote(fn.rsplit(MARK, 1)[1])


def is_open(path):
    try:
        return subprocess.run(["fuser", "-f", path], capture_output=True).returncode == 0
    except FileNotFoundError:
        return False


def update_db(old, new):
    try:
        con = sqlite3.connect(DB)
        con.execute("UPDATE download_db_table SET file_name=? WHERE file_name=?", (new, old))
        con.commit()
        con.close()
    except Exception as e:
        print(f"db error: {e}", file=sys.stderr)


def fix_sidecar(old_side, new_side, new_main):
    try:
        os.rename(old_side, new_side)
        with open(new_side) as f:
            j = json.load(f)
        j["file_name"] = new_main
        with open(new_side, "w") as f:
            json.dump(j, f)
    except Exception as e:
        print(f"sidecar error: {e}", file=sys.stderr)


def main():
    acted = 0
    for sub in SUBDIRS:
        d = os.path.join(BASE, sub)
        if not os.path.isdir(d):
            continue
        for fn in os.listdir(d):
            fpath = os.path.join(d, fn)
            if not os.path.isfile(fpath):
                continue
            new = clean_name(fn)
            if not new or new == fn:
                continue
            npath = os.path.join(d, new)
            if os.path.exists(npath):
                continue
            if os.path.exists(fpath + ".persepolis"):
                continue
            if is_open(fpath):
                continue
            time.sleep(2)
            try:
                os.rename(fpath, npath)
            except OSError as e:
                print(f"rename failed: {e}", file=sys.stderr)
                continue
            old_side = fpath + ".persepolis"
            if os.path.exists(old_side):
                fix_sidecar(old_side, npath + ".persepolis", new)
            update_db(fn, new)
            acted += 1
            print(f"renamed: {npath}")
    if acted:
        print(f"{acted} file(s) renamed")
    return 0


if __name__ == "__main__":
    sys.exit(main())

import ctypes
import json
import os
import subprocess
import sys


def password_matches(password, hashed):
    crypt = ctypes.CDLL("libcrypt.so.1").crypt
    crypt.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
    crypt.restype = ctypes.c_char_p
    return bool(
        password
        and hashed.startswith("$")
        and crypt(password.encode(), hashed.encode()) == hashed.encode()
    )


def console_login_valid(config, shadow, status, mount, backing, matches=password_matches):
    password = config.get("dashboard", {}).get("auth", {}).get("password", "")
    root = [line.split(":") for line in shadow.splitlines() if line.startswith("root:")]
    fields = status.split()
    options = dict(
        item.split("=", 1) for item in mount.get("options", "").split(",") if "=" in item
    )
    upper = os.path.realpath(options.get("upperdir", "/"))
    return (
        len(root) == 1
        and len(root[0]) == 9
        and len(fields) >= 2
        and fields[:2] == ["root", "P"]
        and mount.get("target") == "/etc"
        and mount.get("fstype") == "overlay"
        and upper.startswith("/run/")
        and backing == "tmpfs"
        and matches(password, root[0][1])
    )


def read_command(*args):
    return subprocess.check_output(  # noqa: S603 -- callers supply fixed executables without a shell.
        args, text=True, stderr=subprocess.DEVNULL, timeout=10
    ).strip()


def main():
    try:
        with open("/data/pithead/config.json", encoding="utf-8") as source:
            config = json.load(source)
        with open("/etc/shadow", encoding="utf-8") as source:
            shadow = source.read()
        mount = json.loads(
            read_command("findmnt", "-J", "-M", "/etc", "-o", "TARGET,FSTYPE,OPTIONS")
        )["filesystems"][0]
        options = dict(item.split("=", 1) for item in mount["options"].split(",") if "=" in item)
        backing = read_command("findmnt", "-n", "-T", options["upperdir"], "-o", "FSTYPE")
        valid = console_login_valid(
            config, shadow, read_command("passwd", "-S", "root"), mount, backing
        )
    except Exception:
        valid = False
    print("console login and volatile /etc: " + ("PASS" if valid else "FAIL"))
    return 0 if valid else 1


if __name__ == "__main__":
    sys.exit(main())

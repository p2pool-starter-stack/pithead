import os
import re
import time
from collections import deque

import bcrypt

from mining_dashboard.config import documents

HASH_PATTERN = re.compile(r"\$2[aby]\$(0[4-9]|1[0-6])\$[./A-Za-z0-9]{53}")
NAME_PATTERN = re.compile(r"[A-Za-z0-9._@-]{1,64}")
FAILURE_WINDOW = 60
CLIENT_ATTEMPTS = 5
GLOBAL_ATTEMPTS = 50


def load():
    path = os.environ.get("DASHBOARD_AUTH_FILE", "")
    if not path:
        return {"users": {}, "metrics_password_hash": "", "configured": False}
    with open(path) as stream:
        data = documents.loads(stream.read(65537))
    if not isinstance(data, dict) or not isinstance(data.get("users"), list):
        raise ValueError("Invalid authentication configuration")
    users = {}
    for user in data["users"]:
        if (
            not isinstance(user, dict)
            or not isinstance(user.get("name"), str)
            or not NAME_PATTERN.fullmatch(user["name"])
            or user["name"] in users
            or user.get("role") not in {"admin", "viewer"}
            or not isinstance(user.get("password_hash"), str)
            or not HASH_PATTERN.fullmatch(user["password_hash"])
            or not isinstance(user.get("revision", ""), str)
        ):
            raise ValueError("Invalid authentication configuration")
        users[user["name"]] = user
    if users and not any(u["role"] == "admin" for u in users.values()):
        raise ValueError("An administrator is required")
    machine = data.get("metrics_password_hash", "")
    if not isinstance(machine, str) or (machine and not HASH_PATTERN.fullmatch(machine)):
        raise ValueError("Invalid monitoring credential")
    return {"users": users, "metrics_password_hash": machine, "configured": True}


def password_bytes(password, minimum=1):
    if not isinstance(password, str):
        raise ValueError("Invalid password")
    raw = password.encode()
    if len(password) < minimum or not 1 <= len(raw) <= 72 or b"\0" in raw:
        raise ValueError("Invalid password length or characters")
    return raw


def verify(password, hashed) -> bool:
    try:
        return bcrypt.checkpw(password_bytes(password), hashed.encode())
    except (ValueError, UnicodeError, AttributeError):
        return False


def hash_password(password):
    return bcrypt.hashpw(password_bytes(password, minimum=8), bcrypt.gensalt()).decode()


class Attempts:
    def __init__(self):
        self.entries = deque()

    def start(self, client):
        now = time.monotonic()
        while self.entries and self.entries[0][0] <= now - FAILURE_WINDOW:
            self.entries.popleft()
        if (
            len(self.entries) >= GLOBAL_ATTEMPTS
            or sum(c == client for _, c in self.entries) >= CLIENT_ATTEMPTS
        ):
            return None
        entry = (now, client)
        self.entries.append(entry)
        return entry

    def success(self, entry):
        if entry in self.entries:
            self.entries.remove(entry)


def mask_config(cfg):
    auth = cfg.get("dashboard", {}).get("auth", {})
    if not isinstance(auth, dict):
        return
    if auth.get("metrics_password_hash"):
        auth["metrics_password_hash"] = {"__secret__": True}
    for user in auth.get("users", []) if isinstance(auth.get("users"), list) else []:
        if isinstance(user, dict) and user.get("password_hash"):
            user["password_hash"] = {"__secret__": True}

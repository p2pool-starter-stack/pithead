import json
import socket
import struct


def exact(conn, size):
    data = b""
    while len(data) < size:
        chunk = conn.recv(size - len(data))
        if not chunk:
            raise ConnectionError("short read")
        data += chunk
    return data


def until_nul(conn):
    data = b""
    while not data.endswith(b"\0"):
        data += exact(conn, 1)
    return data[:-1]


def v4(conn):
    _, port, ip = struct.unpack("!BH4s", exact(conn, 7))
    until_nul(conn)
    if ip[:3] == b"\0\0\0" and ip[3]:
        record = {"version": 4, "type": "domain", "host": until_nul(conn).decode(), "port": port}
    else:
        record = {"version": 4, "type": "ipv4", "host": socket.inet_ntoa(ip), "port": port}
    conn.sendall(b"\0\x5b" + bytes(6))
    return record


def v5(conn):
    exact(conn, exact(conn, 1)[0])
    conn.sendall(b"\x05\x00")
    _, _, _, atyp = exact(conn, 4)
    if atyp == 1:
        kind, host = "ipv4", socket.inet_ntoa(exact(conn, 4))
    elif atyp == 3:
        kind, host = "domain", exact(conn, exact(conn, 1)[0]).decode()
    elif atyp == 4:
        kind, host = "ipv6", socket.inet_ntop(socket.AF_INET6, exact(conn, 16))
    else:
        raise ValueError(f"address type {atyp}")
    (port,) = struct.unpack("!H", exact(conn, 2))
    conn.sendall(b"\x05\x05\x00\x01" + bytes(6))
    return {"version": 5, "type": kind, "host": host, "port": port}


server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind((socket.gethostbyname(socket.gethostname()), 1080))
server.listen()
while True:
    conn, _ = server.accept()
    with conn:
        conn.settimeout(10)
        try:
            version = exact(conn, 1)[0]
            record = (
                v4(conn) if version == 4 else v5(conn) if version == 5 else {"version": version}
            )
        except (OSError, ValueError, UnicodeDecodeError) as error:
            record = {"error": str(error)}
        print(json.dumps(record), flush=True)

#!/usr/bin/env python3
"""Read-only local-network pairing diagnosis for a Mac ↔ Windows receiver.

No keyboard/mouse events are sent, and the pairing key is never printed.
Run this from a Terminal granted macOS Local Network access, after pausing
the Mac CrossMouse app (the Windows receiver accepts one client at a time).
"""
from __future__ import annotations

import hashlib
import hmac
from pathlib import Path
import secrets
import socket
import sys


def receive_exact(sock: socket.socket, size: int) -> bytes:
    result = bytearray()
    while len(result) < size:
        data = sock.recv(size - len(result))
        if not data:
            raise ConnectionError("Windows가 인증 응답 없이 연결을 종료함")
        result.extend(data)
    return bytes(result)


def main() -> int:
    config = Path.home() / ".config/crossmouse"
    host = sys.argv[1] if len(sys.argv) > 1 else (config / "host").read_text().strip()
    key = bytes.fromhex((config / "key").read_text().strip())
    if len(key) != 32:
        raise ValueError("Mac 키 파일이 올바른 32바이트 키가 아님")
    nonce = secrets.token_bytes(16)
    client_mac = hmac.digest(key, b"crossmouse-v1-client" + nonce, hashlib.sha256)
    hello = b"CMS1" + nonce + client_mac

    print(f"Windows {host}:49431 에 인증 확인 중 (키는 출력하지 않음)", flush=True)
    with socket.create_connection((host, 49431), timeout=4) as sock:
        sock.settimeout(5)
        sock.sendall(hello)
        reply = receive_exact(sock, 52)
    if reply[:4] != b"CMS1":
        raise ValueError("Windows 응답이 CrossMouse 프로토콜이 아님")
    server_nonce = reply[4:20]
    server_mac = hmac.digest(
        key, b"crossmouse-v1-server" + nonce + server_nonce, hashlib.sha256
    )
    if not hmac.compare_digest(server_mac, reply[20:]):
        raise ValueError("Windows 페어링 키가 Mac 키와 일치하지 않음")
    print("PASS: Windows TCP 연결 및 CrossMouse 상호 인증 성공")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, TimeoutError, ConnectionError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)

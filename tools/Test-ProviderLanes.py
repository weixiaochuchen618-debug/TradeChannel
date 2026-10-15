"""Small HTTPS probes through existing authenticated diagnostic lanes.
No selector, route, account, trading request or operating-system setting changes.
"""
import concurrent.futures
import datetime
import http.client
import json
from pathlib import Path
import re
import socket
import ssl
import struct
import time
from urllib.parse import urlsplit


def receive_exact(sock, length):
    result = b""
    while len(result) < length:
        data = sock.recv(length - len(result))
        if not data:
            raise ConnectionError("proxy closed before handshake completed")
        result += data
    return result


def request(url, port, user=None, password=None, label=""):
    target = urlsplit(url)
    assert target.scheme == "https" and target.hostname
    result = {"lane": label, "url": url, "ok": False}
    sock = None
    start = time.monotonic()
    try:
        sock = socket.create_connection(("127.0.0.1", port), timeout=8)
        sock.settimeout(10)
        method = 2 if user else 0
        sock.sendall(bytes((5, 1, method)))
        if receive_exact(sock, 2) != bytes((5, method)):
            raise ConnectionError("unexpected SOCKS authentication")
        if user:
            ub, pb = user.encode(), password.encode()
            sock.sendall(bytes((1, len(ub))) + ub + bytes((len(pb),)) + pb)
            if receive_exact(sock, 2) != b"\x01\x00":
                raise ConnectionError("diagnostic authentication rejected")
        host = target.hostname.encode("idna")
        sock.sendall(b"\x05\x01\x00\x03" + bytes((len(host),)) + host + struct.pack("!H", target.port or 443))
        head = receive_exact(sock, 4)
        if head[:2] != b"\x05\x00":
            raise ConnectionError("proxy could not establish requested connection")
        length = {1: 4, 4: 16}.get(head[3])
        if head[3] == 3:
            length = receive_exact(sock, 1)[0]
        if length is None:
            raise ConnectionError("invalid proxy response")
        receive_exact(sock, length + 2)
        sock = ssl.create_default_context().wrap_socket(sock, server_hostname=target.hostname)
        path = (target.path or "/") + (("?" + target.query) if target.query else "")
        payload = f"GET {path} HTTP/1.1\r\nHost: {target.hostname}\r\nUser-Agent: TradeChannel-Diagnostic/0.7\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n"
        sock.sendall(payload.encode("ascii"))
        response = http.client.HTTPResponse(sock)
        response.begin()
        body = response.read(262144).decode("utf-8", "replace")
        result.update(status=response.status, ok=200 <= response.status < 300)
        match = re.search(r"(?m)^ip=([^\r\n]+)", body)
        if match:
            result["ip"] = match.group(1).strip()
        elif target.hostname == "myip.ipip.net":
            ips = re.findall(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", body)
            if ips:
                result["ip"] = ips[0]
            result["body_excerpt"] = body[:160].strip()
        response.close()
    except Exception as exc:
        result["error_type"] = type(exc).__name__
    finally:
        if sock:
            sock.close()
        result["total_ms"] = round((time.monotonic() - start) * 1000, 1)
    return result


def main():
    root = Path(r"C:\ProgramData\TradeChannel")
    deployment = json.loads((root / "deployment.json").read_text(encoding="utf-8-sig"))
    manifest = json.loads(Path(deployment["ManifestPath"]).read_text(encoding="utf-8-sig"))
    config = json.loads(Path(manifest["CandidatePath"]).read_text(encoding="utf-8-sig"))
    inbound = next(item for item in config["inbounds"] if item["tag"] == "egress-probe")
    if inbound["listen"] != "127.0.0.1":
        raise RuntimeError("diagnostic inlet must be loopback")
    credentials = {item["username"]: item["password"] for item in inbound["users"]}
    tasks = [
        ("https://1.1.1.1/cdn-cgi/trace", "tradechannel-probe", "Trade-HK"),
        ("https://1.1.1.1/cdn-cgi/trace", "tradechannel-daily", "Daily-Foreign"),
        ("https://myip.ipip.net/", "tradechannel-daily", "Daily-Domestic"),
        ("https://www.youtube.com/generate_204", "tradechannel-daily", "Daily-YouTube"),
        ("https://www.tradingview.com/", "tradechannel-probe", "Trade-TradingView"),
    ]
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        jobs = [pool.submit(request, url, inbound["listen_port"], user, credentials[user], label)
                for url, user, label in tasks]
        results = [job.result() for job in jobs]
    report = {"at": datetime.datetime.now().astimezone().isoformat(), "results": results,
              "scope": "diagnostic users only; ordinary applications remain in their current mode",
              "settings_changed": False}
    path = Path(__file__).resolve().parent.parent / "reports/maintenance-v4/lanes.json"
    path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()

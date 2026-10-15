"""Bounded TCP/TLS probe; no trading credentials, orders or application requests."""
import argparse
import concurrent.futures
import datetime
import json
import socket
import ssl
import struct
import time
import urllib.request
from pathlib import Path


def receive_exact(sock, length):
    result = b""
    while len(result) < length:
        chunk = sock.recv(length - len(result))
        if not chunk:
            raise ConnectionError("Peer closed the connection")
        result += chunk
    return result


def probe(host, port, proxy_port, user=None, password=None):
    result = {"host": host, "port": port, "stage": "local_proxy", "tls_ok": False}
    sock = None
    start = time.perf_counter()
    try:
        sock = socket.create_connection(("127.0.0.1", proxy_port), timeout=6)
        sock.settimeout(6)
        result["local_proxy_ms"] = round((time.perf_counter() - start) * 1000, 1)
        result["stage"] = "proxy_auth"
        method = 2 if user else 0
        sock.sendall(bytes((5, 1, method)))
        if receive_exact(sock, 2) != bytes((5, method)):
            raise ConnectionError("SOCKS negotiation did not accept the expected method")
        if user:
            user_bytes, pass_bytes = user.encode(), password.encode()
            sock.sendall(bytes((1, len(user_bytes))) + user_bytes + bytes((len(pass_bytes),)) + pass_bytes)
            if receive_exact(sock, 2) != b"\x01\x00":
                raise ConnectionError("Local probe authentication rejected")
        result["stage"] = "remote_tcp"
        begin = time.perf_counter()
        host_bytes = host.encode("idna")
        sock.sendall(b"\x05\x01\x00\x03" + bytes((len(host_bytes),)) + host_bytes + struct.pack("!H", port))
        reply = receive_exact(sock, 4)
        if reply[0] != 5 or reply[1] != 0:
            raise ConnectionError("SOCKS connect reply code: " + str(reply[1]))
        if reply[3] == 1:
            receive_exact(sock, 4)
        elif reply[3] == 4:
            receive_exact(sock, 16)
        elif reply[3] == 3:
            receive_exact(sock, receive_exact(sock, 1)[0])
        else:
            raise ConnectionError("Unexpected SOCKS address family")
        receive_exact(sock, 2)
        result["tcp_via_proxy_ms"] = round((time.perf_counter() - begin) * 1000, 1)
        result["stage"] = "tls"
        begin = time.perf_counter()
        context = ssl.create_default_context()
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.maximum_version = ssl.TLSVersion.TLSv1_2
        sock = context.wrap_socket(sock, server_hostname=host)
        result["tls_ms"] = round((time.perf_counter() - begin) * 1000, 1)
        result["tls_ok"] = True
        result["tls_version"] = sock.version()
        result["stage"] = "complete"
    except Exception as exc:
        result["error_type"] = type(exc).__name__
        result["error"] = str(exc)
    finally:
        if sock:
            sock.close()
        result["total_ms"] = round((time.perf_counter() - start) * 1000, 1)
    return result


def main():
    args = argparse.ArgumentParser()
    args.add_argument("--via", choices=("selected", "provider"), required=True)
    args.add_argument("--hosts", nargs="+", default=["hds-us-nt-013.ninjatrader.com", "hds-us-nt-014.ninjatrader.com"])
    args.add_argument("--port", type=int, default=31655)
    options = args.parse_args()
    root = Path(r"C:\ProgramData\TradeChannel")
    deployment = json.loads((root / "deployment.json").read_text(encoding="utf-8-sig"))
    manifest = json.loads(Path(deployment["ManifestPath"]).read_text(encoding="utf-8-sig"))
    username = password = None
    selected_exit = None
    if options.via == "selected":
        cfg = json.loads(Path(manifest["CandidatePath"]).read_text(encoding="utf-8-sig"))
        inbound = next(item for item in cfg["inbounds"] if item["tag"] == "egress-probe")
        proxy_port = inbound["listen_port"]
        username, password = inbound["users"][0]["username"], inbound["users"][0]["password"]
        controller = cfg["experimental"]["clash_api"]
        if not controller["external_controller"].startswith("127.0.0.1:"):
            raise RuntimeError("Only an authenticated loopback controller is accepted")
        request = urllib.request.Request("http://" + controller["external_controller"] + "/proxies/trade-exit",
                                         headers={"Authorization": "Bearer " + controller["secret"]})
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(request, timeout=4) as response:
            selected_exit = json.load(response)["now"]
    else:
        proxy_port = manifest["ProviderSocksPort"]
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        jobs = [pool.submit(probe, host, options.port, proxy_port, username, password) for host in options.hosts]
        results = [job.result() for job in jobs]
    report = {"captured_at": datetime.datetime.now().astimezone().isoformat(), "via": options.via,
              "selected_exit": selected_exit,
              "results": results, "scope": "TCP and verified TLS 1.2 only; no market data authentication or order activity"}
    directory = Path(__file__).resolve().parent.parent / "reports"
    directory.mkdir(exist_ok=True)
    filename = directory / ("hds-path-" + options.via + "-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S") + ".json")
    filename.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    print("Report:", filename)


if __name__ == "__main__":
    main()

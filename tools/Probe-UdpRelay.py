"""Temporary loopback-only WireGuard transport diagnostic; no routes or payload logs."""
import argparse
import ipaddress
import json
import select
import socket
import struct
import time
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--remote', required=True)
    parser.add_argument('--port', type=int, default=51820)
    parser.add_argument('--local-ip', required=True)
    parser.add_argument('--interface-index', type=int, required=True)
    parser.add_argument('--listen-port', type=int, required=True)
    parser.add_argument('--report', required=True)
    args = parser.parse_args()
    ipaddress.IPv4Address(args.remote)
    ipaddress.IPv4Address(args.local_ip)
    if not 1 <= args.port <= 65535 or not 1 <= args.listen_port <= 65535 or args.interface_index <= 0:
        raise ValueError('Invalid port/interface')
    report = Path(args.report)
    report.parent.mkdir(parents=True, exist_ok=True)
    samples = []
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as local, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as remote:
        local.bind(('127.0.0.1', args.listen_port))
        # Windows IP_UNICAST_IF: the interface index is a network-order DWORD.
        remote.setsockopt(socket.IPPROTO_IP, 31, struct.pack('!I', args.interface_index))
        remote.bind((args.local_ip, 0))
        remote.connect((args.remote, args.port))
        deadline = time.monotonic() + 120
        client = None
        def save(status):
            report.write_text(json.dumps({'Status': status, 'InterfaceIndex': args.interface_index,
                'Remote': args.remote, 'LocalEndpoint': remote.getsockname(), 'Samples': samples}, indent=2), encoding='utf-8')
        save('Ready')
        try:
            while time.monotonic() < deadline:
                ready, _, _ = select.select([local, remote], [], [], min(0.2, max(0, deadline - time.monotonic())))
                for stream in ready:
                    data, address = stream.recvfrom(65535)
                    if stream is local:
                        if address[0] != '127.0.0.1' or (client is not None and address != client):
                            continue
                        client = address
                        sent = remote.send(data)
                        direction = 'ToVps'
                    else:
                        if client is None:
                            continue
                        sent = local.sendto(data, client)
                        direction = 'FromVps'
                    kind = int.from_bytes(data[:4], 'little') if len(data) >= 4 else None
                    if len(samples) < 1000:
                        samples.append({'UnixTime': time.time(), 'Direction': direction, 'Bytes': len(data),
                            'SentBytes': sent, 'WgType': kind,
                            'Counter': int.from_bytes(data[8:16], 'little') if kind == 4 and len(data) >= 16 else None})
                    del data
                    save('Running')
        finally:
            save('Finished')


if __name__ == '__main__':
    main()

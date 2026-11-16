#!/usr/bin/env python3
"""Persistent fake Linux server for PS/Jose -> Python/OpenSSL E2E tests.

Request lines: {"Action":"invite_create","Input":{}}
Response lines: standard {Ok,Action,Data,Message}; no SSH/network/real services.
All server paths exist ONLY in MemoryFS. OpenSSL scratch private keys are
private temporary files and immediately removed. Never use this as production
backend: the kernel and initial WireGuard server are intentionally fake.
"""
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location("tc_fixture_kernel", Path(__file__).with_name("test_tcp_backend.py"))
base = importlib.util.module_from_spec(spec); spec.loader.exec_module(base)
tc = base.tc
crypto_path = "/usr/bin/openssl" if os.name == "posix" else r"C:\Program Files\Git\usr\bin\openssl.exe"
fs = base.base.MemoryFS(); kernel = base.TcpOS(fs)
backend = tc.Backend(fs, kernel, management_crypto=tc.management.OpenSSLCrypto(crypto_path), progress=lambda _: None)
configuration = base.base.plan_input()
configuration["PublicEndpoint"] = "1.1.1.1:51820"  # A syntactically accepted fixture; never contacted.
plan = backend.plan(configuration)
backend.apply({"PlanId": plan["PlanId"]})
management_plan = backend.execute("management_plan", {})
backend.execute("management_apply", {"PlanId": management_plan["PlanId"], "ApprovedChangeDigest": management_plan["ChangeDigest"]})

for line in sys.stdin:
    try:
        value = tc.parse_json(line, limit=tc.MAX_INPUT)
        tc.fields(value, ("Action", "Input"))
        result = tc.envelope(value["Action"], value["Input"], backend)
    except tc.TCError as exc:
        result = {"Ok": False, "Action": "FixtureInput", "Data": {"Code": exc.code}, "Message": exc.message}
    except Exception:
        result = {"Ok": False, "Action": "FixtureInput", "Data": {"Code": "FixtureInputFailed"}, "Message": "Invalid test fixture input."}
    sys.stdout.write(tc.dumps(result)); sys.stdout.flush()

"""Real bundled engine regression: supported modes must survive global startup.

All listeners bind loopback; no WireGuard, TUN, DNS, proxy or live controller is
used. The test executable has its own name. Output contains fixture data only.
"""
import argparse
import copy
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.request


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output")
    parser.add_argument("--require-fixed-policy", action="store_true")
    args = parser.parse_args()
    package = Path(__file__).resolve().parent.parent
    shell = Path(os.environ["WINDIR"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"
    env = dict(os.environ, PSModulePath=str(shell.parent / "Modules"))
    observed = []
    with tempfile.TemporaryDirectory(prefix="TC-ModeRegression-") as tmp:
        root = Path(tmp)
        exe = root / "tc-mode-regression.exe"
        shutil.copyfile(package / "assets/sing-box.exe", exe)
        policy_path = root / "policy.json"
        subprocess.run([str(shell), "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                        "-File", str(package / "tests/Export-TestProviderPolicy.ps1"),
                        "-OutputPath", str(policy_path), "-DailyA", "19001", "-DailyB", "19002", "-TradeB", "19003"],
                       check=True, capture_output=True, env=env, timeout=25)
        policy = json.loads(policy_path.read_text(encoding="utf-8-sig"))
        wrapper = root / "invoke-mode.ps1"
        wrapper.write_text("""param($Target,$Config,$Mode,$Output)
$ErrorActionPreference='Stop';$script:flushes=0
function Clear-DnsClientCache { param($ErrorAction) $script:flushes++ }
try { $data=& $Target -Mode $Mode -ConfigPath $Config; $r=@{Ok=$true;Data=$data;Flushes=$script:flushes} }
catch { $r=@{Ok=$false;Error=$_.Exception.Message;Flushes=$script:flushes} }
[IO.File]::WriteAllText($Output,($r|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false)))
""", encoding="utf-8-sig")
        baseline = {
            "log": {"level": "error"},
            "outbounds": [{"type": "direct", "tag": "hk"}] + policy["outbounds"],
            "dns": {"servers": [{"type": "udp", "tag": "dns-direct", "server": "127.0.0.1"},
                                 {"type": "udp", "tag": "dns-trade", "server": "127.0.0.1"}],
                    "rules": policy["dns"]["rules"], "final": "dns-direct"},
            "route": policy["route"],
        }
        legacy = copy.deepcopy(baseline)
        legacy["dns"]["rules"] = [r for r in legacy["dns"]["rules"] if r.get("clash_mode") != "rule"]
        fixed = copy.deepcopy(legacy)
        fixed["dns"]["rules"].append({"clash_mode": "rule", "action": "route", "server": "dns-direct"})
        for label, default, config in (("legacy-rule-start", "rule", legacy),
                                       ("legacy-global-start", "global", legacy),
                                       ("explicit-modes-global-start", "global", fixed),
                                       ("generated-policy-global-start", "global", baseline)):
            port = free_port()
            config = copy.deepcopy(config)
            config["experimental"] = {"clash_api": {"external_controller": f"127.0.0.1:{port}",
                                                    "secret": "fixture-only", "default_mode": default}}
            path = root / (label + ".json")
            path.write_text(json.dumps(config), encoding="utf-8")
            subprocess.run([str(exe), "check", "-c", str(path)], check=True, capture_output=True, timeout=15)
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

            def api(mode=None):
                req = urllib.request.Request(f"http://127.0.0.1:{port}/configs", method="GET" if mode is None else "PATCH",
                                             data=None if mode is None else json.dumps({"mode": mode}).encode(),
                                             headers={"Authorization": "Bearer fixture-only", "Content-Type": "application/json"})
                with opener.open(req, timeout=2) as response:
                    text = response.read()
                    return response.status, json.loads(text) if text else None

            log = open(root / (label + ".log"), "wb")
            proc = subprocess.Popen([str(exe), "run", "-c", str(path)], stdout=log, stderr=log,
                                    creationflags=subprocess.CREATE_NO_WINDOW)
            try:
                for _ in range(60):
                    try:
                        before = api()[1]
                        break
                    except (OSError, urllib.error.URLError):
                        if proc.poll() is not None:
                            raise RuntimeError("Isolated engine stopped")
                        time.sleep(0.05)
                else:
                    raise RuntimeError("Isolated controller startup timed out")
                status = api("rule")[0]
                time.sleep(1.7)
                after = api()[1]
                api("global")
                global_after = api()[1]["mode"]
                entry = {"Case": label, "Default": default, "Available": before["mode-list"],
                         "PatchHTTP": status, "Requested": "rule", "ActualAfterWait": after["mode"],
                         "ReturnGlobal": global_after}
                observed.append(entry)
                if label == "legacy-global-start":
                    assert before["mode-list"] == ["global"] and status == 204 and after["mode"] == "global", entry
                if label in ("legacy-rule-start", "explicit-modes-global-start") or (args.require_fixed_policy and label == "generated-policy-global-start"):
                    assert {"rule", "global"} <= set(before["mode-list"]), entry
                    assert after["mode"] == "rule" and global_after == "global", entry
                if args.require_fixed_policy:
                    result_path = root / "mode-result.json"
                    for requested in ("Trading", "Global"):
                        subprocess.run([str(shell), "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                                        "-File", str(wrapper), "-Target", str(package / "runtime/Set-TradeChannelMode.ps1"),
                                        "-Config", str(path), "-Mode", requested, "-Output", str(result_path)],
                                       env=env, check=True, capture_output=True, timeout=15)
                        r = json.loads(result_path.read_text(encoding="utf-8-sig"))
                        if label == "legacy-global-start" and requested == "Trading":
                            assert not r["Ok"] and "TC:ModeUnavailable" in r["Error"] and r["Flushes"] == 0, r
                            assert api()[1]["mode"] == "global"
                        else:
                            assert r["Ok"], r
                            assert r["Data"]["ControllerMode"] == ("rule" if requested == "Trading" else "global"), r
                    entry["ProductScriptChecked"] = True
            finally:
                proc.terminate()
                proc.wait(timeout=8)
                log.close()
    result = {"Passed": True, "Cases": observed, "RealNetworkChanges": 0, "Scope": "loopback controller only"}
    if args.output:
        Path(args.output).parent.mkdir(parents=True, exist_ok=True)
        Path(args.output).write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()

"""Bounded network-only drill with unreachable HK peer and SOCKS TCP fault relay.

Requires NinjaTrader closed. Never places orders or changes the real server.
Copies configurations to the protected directory, restores the selected production
deployment/mode/exit in finally, and preserves the NinjaTrader WFP protection.
"""
import argparse
import base64
import copy
import datetime as dt
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import sys
import threading
import time
import tempfile
import urllib.error
import urllib.request

sys.dont_write_bytecode = True
ROOT = Path(r"C:\ProgramData\TradeChannel")
WORKSPACE = Path(__file__).resolve().parent.parent
TOOLS = WORKSPACE / "tools"
POWERSHELL = str(Path(os.environ["WINDIR"]) / r"System32\WindowsPowerShell\v1.0\powershell.exe")
CURL = str(Path(os.environ["WINDIR"]) / r"System32\curl.exe")
PROBE = ROOT / "bin" / "trade-probe.exe"
NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)


def now():
    return dt.datetime.now().astimezone().isoformat(timespec="milliseconds")


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def write_json(path, value):
    path = Path(path)
    temp = path.with_name(path.name + ".next")
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(temp, path)


def quote_ps(value):
    return "'" + str(value).replace("'", "''") + "'"


def ps(code, timeout=35):
    source = "$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false);\n" + code
    encoded = base64.b64encode(source.encode("utf-16-le")).decode()
    # Start-Process descendants may inherit redirected pipe handles on Windows.
    # File-backed capture lets us wait on this process, not the long-lived child.
    with tempfile.TemporaryFile(dir=ROOT, mode="w+b") as out, tempfile.TemporaryFile(dir=ROOT, mode="w+b") as err:
        process = subprocess.Popen([POWERSHELL, "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded],
                        stdin=subprocess.DEVNULL, stdout=out, stderr=err, creationflags=NO_WINDOW)
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)
            raise RuntimeError("PowerShell operation exceeded its bounded timeout") from None
        out.seek(0)
        output = out.read().decode("utf-8-sig", errors="replace").strip()
        err.seek(0)
        error_output = err.read().decode("utf-8-sig", errors="replace").strip()
    if process.returncode:
        # Keep raw diagnostics in the protected directory, never echo key-bearing
        # command output to the conversation. This preserves the failure cause.
        error_path = ROOT / "logs" / ("scenario-command-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S-%f") + ".txt")
        error_path.write_text(error_output or output, encoding="utf-8")
        raise RuntimeError("PowerShell operation failed with code " + str(process.returncode) + "; protected diagnostic: " + str(error_path))
    return output


def run_action(action):
    output = ps("& " + quote_ps(TOOLS / "Invoke-TradeChannel.ps1") + " -Action " + action +
                " | ConvertTo-Json -Depth 6", timeout=40)
    return json.loads(output) if output else None


def app_state():
    return json.loads(ps("[pscustomobject]@{NinjaRunning=[bool](Get-Process -Name NinjaTrader -ErrorAction SilentlyContinue);"
        "ProviderRunning=[bool](Get-Process -Name v2ray -ErrorAction SilentlyContinue);"
        "ProviderListening=(@([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()|"
        "Where-Object {$_.Port -eq 10823}).Count -gt 0)}|ConvertTo-Json -Compress"))


def guard_state():
    return json.loads(ps("Add-Type -Path " + quote_ps(TOOLS / "TradeChannelGuard.cs") +
        ";$g=[TradeChannelGuard]::GetStatus();[pscustomobject]@{ProviderPresent=$g.ProviderPresent;"
        "Blocks=@($g.Filters|Where-Object {$_.IsBlock -and $_.IsPersistent}).Count;"
        "Permits=@($g.Filters|Where-Object {$_.IsPermit}).Count;"
        "Recognized=@($g.Filters|Where-Object {$_.Recognized}).Count;"
        "FilterDetails=@($g.Filters|Select-Object Family,ApplicationId,IsPersistent,IsBlock,IsPermit,IsDisabled,Recognized)}|ConvertTo-Json -Depth 5 -Compress"))


def controller(config, path, method="GET", payload=None):
    api = config["experimental"]["clash_api"]
    if not api["external_controller"].startswith("127.0.0.1:"):
        raise RuntimeError("Only loopback control is accepted")
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request("http://" + api["external_controller"] + path, data=data, method=method,
         headers={"Authorization": "Bearer " + api["secret"], "Content-Type": "application/json"})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(req, timeout=4) as response:
        body = response.read()
    return json.loads(body) if body else None


class ProviderRelay:
    """Fault injection for SOCKS TCP only; BatVPN itself and its UI stay running."""
    def __init__(self, provider_port):
        self.provider_port = provider_port
        self.local = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.local.bind(("127.0.0.1", 0))
        self.local.listen(32)
        self.local.settimeout(0.3)
        self.port = self.local.getsockname()[1]
        self.enabled = True
        self.stopped = threading.Event()
        self.lock = threading.Lock()
        self.pairs = set()
        self.counts = {"connections": 0, "blocked": 0}
        self.thread = threading.Thread(target=self.work, daemon=True)
        self.thread.start()

    def work(self):
        while not self.stopped.is_set():
            try:
                client, _ = self.local.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            if not self.enabled:
                self.counts["blocked"] += 1
                client.close()
            else:
                threading.Thread(target=self.forward, args=(client,), daemon=True).start()

    def forward(self, client):
        remote = None
        pair = None
        try:
            remote = socket.create_connection(("127.0.0.1", self.provider_port), timeout=4)
            pair = (client, remote)
            with self.lock:
                self.pairs.add(pair)
            self.counts["connections"] += 1
            while self.enabled and not self.stopped.is_set():
                ready, _, _ = select.select(pair, [], [], 0.3)
                for source in ready:
                    data = source.recv(65536)
                    if not data:
                        return
                    (remote if source is client else client).sendall(data)
        except (OSError, ValueError):
            pass
        finally:
            if pair:
                with self.lock:
                    self.pairs.discard(pair)
            client.close()
            if remote:
                remote.close()

    def disable(self):
        self.enabled = False
        with self.lock:
            for pair in list(self.pairs):
                for item in pair:
                    try:
                        item.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass

    def close(self):
        self.stopped.set()
        self.disable()
        self.local.close()
        self.thread.join(1)


def http_probe(executable, url, config=None, body=False, timeout=7, connect_timeout=4):
    def esc(value):
        return str(value).replace("\\", "\\\\").replace('"', '\\"')
    lines = ["silent", "show-error", "ipv4", "connect-timeout = " + str(connect_timeout), "max-time = " + str(timeout),
             'url = "' + esc(url) + '"', 'write-out = "\\nTC_STATUS:%{http_code}\\nTC_REMOTE:%{remote_ip}"']
    if not body:
        lines += ["head", 'output = "NUL"']
    if config:
        inlet = next(item for item in config["inbounds"] if item["tag"] == "egress-probe")
        user = inlet["users"][0]
        lines += ['proxy = "http://127.0.0.1:' + str(inlet["listen_port"]) + '"',
                  'proxy-user = "' + esc(user["username"] + ":" + user["password"]) + '"', 'noproxy = ".invalid"']
    else:
        lines += ['noproxy = "*"']
    begin = time.perf_counter()
    process = subprocess.run([str(executable), "--config", "-"], input="\n".join(lines).encode(),
                             capture_output=True, timeout=timeout + 4, creationflags=NO_WINDOW)
    value = process.stdout.decode(errors="replace")
    output = {"url": url, "exit_code": process.returncode, "http_status": None,
              "observed_ip": None, "total_ms": round((time.perf_counter() - begin) * 1000, 1)}
    for line in value.splitlines():
        if line.startswith("TC_STATUS:"):
            output["http_status"] = int(line.split(":", 1)[1])
        elif line.startswith("ip="):
            try:
                output["observed_ip"] = str(ipaddress.ip_address(line[3:].strip()))
            except ValueError:
                pass
        elif line and not line.startswith("TC_"):
            try:
                output["observed_ip"] = str(ipaddress.ip_address(line.strip()))
            except ValueError:
                pass
    return output


class Drill:
    def __init__(self, phase):
        self.phase = phase
        self.deployment_path = ROOT / "deployment.json"
        self.original_deployment = self.deployment_path.read_bytes()
        self.deployment = json.loads(self.original_deployment.decode("utf-8-sig"))
        self.manifest = read_json(self.deployment["ManifestPath"])
        self.original_config_path = Path(self.manifest["CandidatePath"])
        self.original_config = read_json(self.original_config_path)
        self.original_config_bytes = self.original_config_path.read_bytes()
        self.original_mode = controller(self.original_config, "/configs")["mode"]
        self.original_exit = controller(self.original_config, "/proxies/trade-exit")["now"]
        self.before_state = app_state()
        self.original_guard = guard_state()
        if self.before_state["NinjaRunning"]:
            raise RuntimeError("NinjaTrader must be closed for the fault drill")
        if phase == "hongkong-only" and self.before_state["ProviderListening"]:
            raise RuntimeError("Disconnect BatVPN for the Hong Kong-only phase")
        if phase != "hongkong-only" and not self.before_state["ProviderListening"]:
            raise RuntimeError("Connect BatVPN in global mode for the provider phase")
        if not PROBE.exists():
            raise RuntimeError("Dedicated probe executable is missing")
        self.stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        self.private = ROOT / "scenario-tests" / self.stamp
        self.private.mkdir(parents=True)
        self.report_path = WORKSPACE / "reports" / ("scenarios-" + phase + "-" + self.stamp + ".json")
        self.report = {"started_at": now(), "phase": phase, "original_mode": self.original_mode,
                       "original_exit": self.original_exit, "initial_process_state": self.before_state,
                       "cases": [], "error": None, "restoration": None,
                       "scope": "Independent probe follows a cloned trading-process route. No order or account action; TCP/HTTPS/TLS only.",
                       "limits": ["Probe results do not establish full NinjaTrader HDS downloads or order handling.",
                                  "BatVPN transport fault relay affects TCP; UDP/QUIC and host reboot are not tested.",
                                  "No new automatic-failover behavior is introduced."]}
        self.provider = None
        self.changed = False
        self.config = None
        self.flush_report()

    def flush_report(self):
        write_json(self.report_path, self.report)

    def case(self, name, outcome, details):
        item = {"name": name, "recorded_at": now(), "outcome": outcome, "details": details}
        self.report["cases"].append(item)
        self.flush_report()
        print(json.dumps(item, ensure_ascii=False), flush=True)

    def set_exit(self, target, preflight=True):
        if target == "provider" and preflight:
            run_action("Provider")
        else:
            controller(self.config, "/proxies/trade-exit", "PUT", {"name": target})
            controller(self.config, "/cache/dns/flush", "POST")
            ps("Clear-DnsClientCache")
        if controller(self.config, "/proxies/trade-exit")["now"] != target:
            raise RuntimeError("Exit selection read-back failed")

    def set_mode(self, mode):
        run_action("Trading" if mode == "rule" else "Global")

    def egress(self, trading=False, selected=False):
        # Same destination for ordinary and designated trading probes.
        return http_probe(PROBE if trading else CURL, "https://ip.3322.net", self.config if selected else None, True)

    def echo_selected(self):
        return http_probe(CURL, "https://1.1.1.1/cdn-cgi/trace", self.config, True)

    def website_route(self):
        # Hold a bounded ordinary-curl HTTPS download so the controller can report
        # its domain rule/exit. HTTP 200 alone cannot prove which route was used.
        process = subprocess.Popen([CURL, "--noproxy", "*", "-4", "--silent", "--show-error",
                    "--output", "NUL", "--limit-rate", "2048", "--connect-timeout", "4",
                    "--max-time", "6", "https://www.tradingview.com/"],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, creationflags=NO_WINDOW)
        result = None
        try:
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                connections = controller(self.config, "/connections")["connections"]
                for item in connections:
                    metadata = item.get("metadata", {})
                    if metadata.get("host") == "www.tradingview.com" and str(metadata.get("processPath", "")).lower().startswith(CURL.lower()):
                        result = {"domain": metadata["host"], "process": "ordinary curl.exe",
                                  "chain": item.get("chains", []), "rule": item.get("rule")}
                        break
                if result or process.poll() is not None:
                    break
                time.sleep(0.2)
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=3)
        return result

    def verify_routes(self, label, expected, local):
        trade = self.egress(trading=True)
        ordinary = self.egress()
        web = http_probe(CURL, "https://www.tradingview.com/")
        selected = controller(self.config, "/proxies/trade-exit")["now"]
        web_route = self.website_route()
        passed = (trade["exit_code"] == 0 and trade["http_status"] == 200 and trade["observed_ip"] == expected
                  and ordinary["exit_code"] == 0 and ordinary["http_status"] == 200 and ordinary["observed_ip"] == local
                  and web["exit_code"] == 0 and web["http_status"] == 200
                  and web_route is not None and selected in web_route["chain"])
        self.case(label, "pass" if passed else "fail", {"trade_program": trade, "ordinary_program": ordinary, "tradingview": web,
                 "tradingview_route": web_route, "selected_exit": selected})
        return passed

    def start(self):
        peer = next(item for item in self.original_config["endpoints"] if item["tag"] == "hk")["peers"][0]
        self.provider = ProviderRelay(self.manifest["ProviderSocksPort"])
        self.config = copy.deepcopy(self.original_config)
        provider_out = next(item for item in self.config["outbounds"] if item["tag"] == "provider")
        provider_out["server_port"] = self.provider.port
        # The local test relay must reach the provider core without recursive routing.
        self.config["route"]["rules"].insert(0, {"process_path": [sys.executable], "action": "route", "outbound": "direct"})
        for rules in [self.config["route"]["rules"], self.config["dns"]["rules"]]:
            for rule in rules:
                paths = rule.get("process_path", [])
                if set(paths) & set(self.manifest["TradeProgramPaths"]):
                    rule["process_path"] = list(dict.fromkeys(paths + [str(PROBE)]))
        self.config["log"]["level"] = "info"
        test_config = self.private / "scenario.json"
        test_manifest = self.private / "manifest.json"
        write_json(test_config, self.config)
        manifest = copy.deepcopy(self.manifest)
        manifest["CandidatePath"] = str(test_config)
        # The production NinjaTrader guard is retained; routing probe is not a guard test.
        write_json(test_manifest, manifest)
        check = subprocess.run([manifest["EnginePath"], "check", "-c", str(test_config)], capture_output=True, creationflags=NO_WINDOW)
        if check.returncode:
            raise RuntimeError("Scenario config failed engine validation; diagnostics suppressed")
        self.case("configuration", "pass", {"cloned": True, "HK_fault_method": "temporary unreachable endpoint with controlled test-engine restart",
                  "uses_provider_TCP_fault_relay": True, "new_routes_do_not_apply_to_real_NinjaTrader_session": True})
        self.changed = True
        run_action("Emergency")
        test_deployment = copy.deepcopy(self.deployment)
        test_deployment["ManifestPath"] = str(test_manifest)
        write_json(self.deployment_path, test_deployment)
        run_action("Trading")
        local_probe = self.egress()
        hk_probe = self.echo_selected()
        self.local_ip = local_probe["observed_ip"]
        self.hk_ip = hk_probe["observed_ip"]
        if not self.local_ip or self.hk_ip != peer["address"]:
            self.case("baseline", "fail", {"local": local_probe, "hk": hk_probe,
                      "configured_hk_is_real": True})
            raise RuntimeError("HK relay baseline was not established")
        self.case("baseline", "pass", {"local_ip": self.local_ip, "hk_ip": self.hk_ip, "guard": guard_state()})

    def set_hk_available(self, available):
        """Controlled restart, preserving mode/selection; no production file edits."""
        if not available:
            occupied = json.loads(ps("@([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveUdpListeners()|Where-Object {$_.Port -eq 9}).Count|ConvertTo-Json -Compress"))
            if occupied:
                raise RuntimeError("UDP fault-simulation port 9 is occupied")
        mode = controller(self.config, "/configs")["mode"]
        selected = controller(self.config, "/proxies/trade-exit")["now"]
        run_action("Emergency")
        peer = next(item for item in self.config["endpoints"] if item["tag"] == "hk")["peers"][0]
        original_peer = next(item for item in self.original_config["endpoints"] if item["tag"] == "hk")["peers"][0]
        peer["address"] = original_peer["address"] if available else "127.0.0.1"
        peer["port"] = original_peer["port"] if available else 9
        next(item for item in self.config["outbounds"] if item["tag"] == "trade-exit")["default"] = selected
        # Keep production default "rule": sing-box derives its advertised mode
        # list from the default plus explicit clash_mode rules. Writing default
        # "global" here can remove "rule" and make a later PATCH silently ignored.
        # run_action below restores the chosen mode after the controlled restart.
        self.config["experimental"]["clash_api"]["default_mode"] = self.original_config["experimental"]["clash_api"]["default_mode"]
        write_json(self.private / "scenario.json", self.config)
        run_action("Trading" if mode == "rule" else "Global")
        if controller(self.config, "/proxies/trade-exit")["now"] != selected:
            raise RuntimeError("Fault injection unexpectedly changed the selected exit")

    def run(self):
        self.start()
        if self.phase == "recovery-only":
            self.set_mode("global")
            self.provider.disable()
            self.set_hk_available(False)
            outage = self.egress()
            self.case("repeat_dual_failure_precondition", "pass" if outage["exit_code"] != 0 else "fail", outage)
            self.set_hk_available(True)
            self.provider.enabled = True
            self.set_mode("rule")
            self.set_exit("hk")
            healthy = self.echo_selected()
            self.case("both_recovered_manual_HK", "pass" if healthy["exit_code"] == 0 and healthy["http_status"] == 200 and healthy["observed_ip"] == self.hk_ip else "fail", healthy)
            run_action("Emergency")
            guard = guard_state()
            ordinary = self.egress()
            self.case("channel_stopped_guard_retained", "policy_state_pass" if guard["Blocks"] == 2 and guard["Permits"] == 0 and ordinary["observed_ip"] == self.local_ip else "fail",
                      {"guard": guard, "ordinary": ordinary, "scope": "Original protected executable remains closed; verifies installed policy plus ordinary connectivity."})
            return
        if self.phase == "provider-recheck":
            self.set_exit("provider")
            self.provider_ip = self.echo_selected()["observed_ip"]
            if not self.provider_ip or self.provider_ip in (self.local_ip, self.hk_ip):
                raise RuntimeError("Provider recheck egress precondition failed")
            self.set_hk_available(False)
            self.verify_routes("provider_only_routing_recheck", self.provider_ip, self.local_ip)
            long_web = http_probe(CURL, "https://www.tradingview.com/", timeout=18, connect_timeout=12)
            self.case("provider_tradingview_extended_deadline", "diagnostic", {"probe": long_web, "note": "Longer deadline does not erase the 4-second timeout observed in the earlier run."})
            self.set_mode("global")
            self.verify_routes("provider_global_routing_recheck", self.provider_ip, self.provider_ip)
            return
        if self.phase == "hongkong-only":
            self.verify_routes("1_HK_only_trading", self.hk_ip, self.local_ip)
            try:
                run_action("Provider")
                rejected = False
            except RuntimeError:
                rejected = True
            selected = controller(self.config, "/proxies/trade-exit")["now"]
            self.case("provider_absent_manual_switch", "pass" if rejected and selected == "hk" else "fail",
                      {"switch_rejected": rejected, "selected_exit": selected})
            self.set_mode("global")
            self.verify_routes("HK_only_global", self.hk_ip, self.hk_ip)
            self.set_mode("rule")
            return

        self.verify_routes("3_both_running_HK_selected", self.hk_ip, self.local_ip)
        self.set_exit("provider")
        self.provider_ip = self.echo_selected()["observed_ip"]
        if not self.provider_ip or self.provider_ip in (self.hk_ip, self.local_ip):
            raise RuntimeError("Independent provider egress baseline was not established")
        self.verify_routes("3_both_running_provider_selected", self.provider_ip, self.local_ip)
        self.set_exit("hk")
        self.set_hk_available(False)
        began = time.perf_counter()
        observations = []
        for _ in range(3):
            observations.append({"elapsed_s": round(time.perf_counter()-began, 1),
                                 "exit": controller(self.config, "/proxies/trade-exit")["now"],
                                 "probe": self.echo_selected()})
            time.sleep(1)
        changed = any(item["exit"] != "hk" for item in observations)
        failed = all(item["probe"]["exit_code"] != 0 for item in observations)
        self.case("4_HK_live_failure_automatic_switch", "not_implemented" if failed and not changed else "unexpected",
                  {"automatic_switch_observed": changed, "observation_seconds": round(time.perf_counter()-began, 1),
                   "samples": observations, "HK_fault_method": "unreachable local UDP endpoint; test engine restarted before observation",
                   "provider_core_still_running": app_state()["ProviderRunning"]})
        self.set_exit("provider")
        self.verify_routes("2_provider_only_HK_unreachable_manual_recovery", self.provider_ip, self.local_ip)
        spec = importlib.util.spec_from_file_location("hdsprobe", TOOLS / "Test-HistoricalDataPath.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        inlet = next(item for item in self.config["inbounds"] if item["tag"] == "egress-probe")
        user = inlet["users"][0]
        hds = [module.probe(host, 31655, inlet["listen_port"], user["username"], user["password"])
               for host in ("hds-us-nt-013.ninjatrader.com", "hds-us-nt-014.ninjatrader.com")]
        self.case("provider_historical_TLS", "transport_pass_only" if all(x["tls_ok"] for x in hds) else "degraded", hds)
        self.set_mode("global")
        self.verify_routes("provider_only_global", self.provider_ip, self.provider_ip)
        self.set_mode("rule")
        self.set_hk_available(True)
        time.sleep(1)
        selected = controller(self.config, "/proxies/trade-exit")["now"]
        egress = self.echo_selected()
        self.case("HK_recovery_no_automatic_failback", "pass" if selected == "provider" and egress["observed_ip"] == self.provider_ip else "fail",
                  {"selected_exit": selected, "probe": egress})
        self.set_exit("hk")
        recovered = self.echo_selected()
        self.case("manual_failback_to_HK", "pass" if recovered["observed_ip"] == self.hk_ip else "fail", recovered)
        self.provider.disable()
        self.verify_routes("provider_TCP_failure_while_HK_selected", self.hk_ip, self.local_ip)
        self.set_exit("provider", preflight=False)
        provider_failure = self.echo_selected()
        ordinary = self.egress()
        selected = controller(self.config, "/proxies/trade-exit")["now"]
        self.case("selected_provider_failure_no_direct_fallback", "pass" if provider_failure["exit_code"] != 0 and ordinary["observed_ip"] == self.local_ip and selected == "provider" else "fail",
                  {"selected_exit": selected, "failed_selected_probe": provider_failure, "ordinary_program": ordinary,
                   "selection_note": "Raw controller selects simulated failed transport; no availability-preflight claim."})
        self.set_hk_available(False)
        self.set_exit("hk")
        both = self.echo_selected()
        web = http_probe(CURL, "https://www.tradingview.com/")
        ordinary = self.egress()
        self.case("both_transports_failed_trading_mode", "pass" if both["exit_code"] != 0 and web["exit_code"] != 0 and ordinary["observed_ip"] == self.local_ip else "fail",
                  {"selected_probe": both, "tradingview": web, "ordinary": ordinary})
        self.set_mode("global")
        global_failure = self.egress()
        self.case("both_transports_failed_global_mode", "pass" if global_failure["exit_code"] != 0 else "fail", global_failure)
        self.set_hk_available(True)
        self.provider.enabled = True
        self.set_mode("rule")
        self.set_exit("hk")
        restored = self.echo_selected()
        self.case("both_recovered_manual_HK", "pass" if restored["observed_ip"] == self.hk_ip else "fail", restored)
        run_action("Emergency")
        guard = guard_state()
        ordinary = self.egress()
        self.case("channel_stopped_guard_retained", "policy_state_pass" if guard["Blocks"] == 2 and guard["Permits"] == 0 and ordinary["observed_ip"] == self.local_ip else "fail",
                  {"guard": guard, "ordinary": ordinary, "scope": "Filter state; no real NinjaTrader process launched during drill."})

    def restore(self):
        errors = []
        if self.changed:
            try:
                run_action("Emergency")
            except Exception as exc:
                errors.append("Stop test: " + type(exc).__name__)
            # Check verified test-engine ownership before removing its transport.
            try:
                runtime = read_json(ROOT / "runtime.json")
                cfgpath = str(runtime.get("ConfigPath", ""))
                if cfgpath.startswith(str(self.private) + "\\"):
                    for key in ("SupervisorPid", "EnginePid"):
                        number = runtime.get(key)
                        if number:
                            allowed_path = self.private / ("manifest.json" if key == "SupervisorPid" else "scenario.json")
                            ps("$p=Get-CimInstance Win32_Process -Filter " + quote_ps("ProcessId=" + str(int(number))) +
                               ";if($p -and $p.CommandLine -and $p.CommandLine.Contains(" + quote_ps(allowed_path) +
                               ")){Stop-Process -Id " + str(int(number)) + " -Force}")
            except Exception as exc:
                errors.append("Test-process cleanup: " + type(exc).__name__)
            try:
                temp = self.deployment_path.with_name("deployment.restore.tmp")
                temp.write_bytes(self.original_deployment)
                os.replace(temp, self.deployment_path)
            except Exception as exc:
                errors.append("Deployment restore: " + type(exc).__name__)
        if self.provider:
            try:
                self.provider.close()
            except Exception as exc:
                errors.append("Provider relay close: " + type(exc).__name__)
        try:
            deployment_restored = self.deployment_path.read_bytes() == self.original_deployment
            config_unchanged = self.original_config_path.read_bytes() == self.original_config_bytes
        except Exception as exc:
            deployment_restored = config_unchanged = False
            errors.append("Restore read-back: " + type(exc).__name__)
        final = None
        if self.changed and deployment_restored and config_unchanged:
            try:
                run_action("Trading" if self.original_mode == "rule" else "Global")
                run_action("HongKong" if self.original_exit == "hk" else "Provider")
                final = {"mode": controller(self.original_config, "/configs")["mode"],
                         "exit": controller(self.original_config, "/proxies/trade-exit")["now"],
                         "egress": http_probe(CURL, "https://1.1.1.1/cdn-cgi/trace", self.original_config, True),
                         "guard": guard_state()}
                runtime = read_json(ROOT / "runtime.json")
                final["runtime_manifest_matches"] = runtime.get("ManifestPath") == self.deployment["ManifestPath"]
                final["runtime_config_matches"] = runtime.get("ConfigPath") == str(self.original_config_path)
                final["runtime_running"] = runtime.get("State") == "Running"
                final["identified_processes_alive"] = json.loads(ps(
                    "$s=Get-Content -LiteralPath 'C:\\ProgramData\\TradeChannel\\runtime.json' -Raw|ConvertFrom-Json;"
                    "$e=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$s.EnginePid);"
                    "$p=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$s.SupervisorPid);"
                    "[pscustomobject]@{Engine=[bool]($e -and $e.CommandLine -and $e.CommandLine.Contains($s.ConfigPath));"
                    "Supervisor=[bool]($p -and $p.CommandLine -and $p.CommandLine.Contains($s.ManifestPath))}|ConvertTo-Json -Compress"))
                details = final["guard"]["FilterDetails"] or []
                expected = {(x["ApplicationId"], x["Family"]) for x in self.original_guard["FilterDetails"] if x["IsBlock"]}
                blocks = {(x["ApplicationId"], x["Family"]) for x in details if x["IsBlock"] and x["IsPersistent"]}
                permits = {(x["ApplicationId"], x["Family"]) for x in details if x["IsPermit"]}
                final["guard_paths_and_families_restored"] = (bool(expected) and blocks == expected and permits == expected
                    and all(x["Recognized"] and not x["IsDisabled"] for x in details))
                p = final["egress"]
                expected_egress = (next(x for x in self.original_config["endpoints"] if x["tag"] == "hk")["peers"][0]["address"]
                                   if self.original_exit == "hk" else getattr(self, "provider_ip", None))
                final["accepted"] = (final["mode"] == self.original_mode and final["exit"] == self.original_exit
                    and final["runtime_manifest_matches"] and final["runtime_config_matches"] and final["runtime_running"]
                    and all(final["identified_processes_alive"].values()) and final["guard_paths_and_families_restored"]
                    and p["exit_code"] == 0 and p["http_status"] == 200 and p["observed_ip"] == expected_egress)
                if not final["accepted"]:
                    errors.append("Production restoration acceptance failed; inspect final evidence")
            except Exception as exc:
                errors.append("Production restart: " + type(exc).__name__)
        elif self.changed:
            errors.append("Production restart withheld because restored files did not match the originals")
        self.report["restoration"] = {"deployment_bytes_restored": deployment_restored,
             "production_config_unchanged": config_unchanged,
             "final": final, "errors": errors}
        self.report["finished_at"] = now()
        self.flush_report()
        # Remove only known generated secret-bearing configs after verified restore.
        if self.report["restoration"]["deployment_bytes_restored"] and not errors:
            for name in ("scenario.json", "manifest.json"):
                target = self.private / name
                if target.exists():
                    target.unlink()
            if not any(self.private.iterdir()):
                self.private.rmdir()
        print(json.dumps({"report": str(self.report_path), "restoration": self.report["restoration"]}, ensure_ascii=False), flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--phase", choices=("hongkong-only", "provider-matrix", "recovery-only", "provider-recheck"), required=True)
    phase = parser.parse_args().phase
    drill = Drill(phase)
    try:
        drill.run()
    except Exception as exc:
        drill.report["error"] = {"type": type(exc).__name__, "message": str(exc) if not isinstance(exc, subprocess.TimeoutExpired) else "Bounded subprocess timed out"}
        print(json.dumps({"error": drill.report["error"]}), flush=True)
    finally:
        drill.restore()
    if (drill.report["error"] or drill.report["restoration"]["errors"]
            or any(item["outcome"] in ("fail", "unexpected", "degraded") for item in drill.report["cases"])):
        raise SystemExit(1)


if __name__ == "__main__":
    main()

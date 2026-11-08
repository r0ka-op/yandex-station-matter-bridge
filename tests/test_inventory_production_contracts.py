#!/usr/bin/env python3
"""Independent source-contract checks for the full-inventory launch chain."""
from __future__ import annotations
import json, re, time
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
S=ROOT/"scripts"
cases=[]
def check(name, condition, detail):
    cases.append({"name":name,"pass":bool(condition),"detail":detail})

entry=(S/"start_maind_http_full_inventory.ps1").read_text(encoding="utf-8-sig")
controller=(S/"start_maind_http_runtime_test.ps1").read_text(encoding="utf-8-sig")
inventory=(S/"maind_http_inventory_helpers.ps1").read_text(encoding="utf-8-sig")
remote=(S/"maind_http_runtime_test_remote.sh").read_text(encoding="utf-8")
mock=(S/"mock_maind_ssh_transport.py").read_text(encoding="utf-8")
launcher=(S/"mock_ssh_launcher"/"Program.cs").read_text(encoding="utf-8-sig")

check("entry-runtime-chain", "-InternalFullInventory" in entry and "start_maind_http_runtime_test.ps1" in entry,
      "full inventory delegates to the production runtime controller")
helpers=re.findall(r'\. \(Join-Path \$root "scripts\\([^\"]+helpers\.ps1)"\)',controller)
check("production-helper-set", set(helpers)=={
    "maind_http_target_helpers.ps1",
    "maind_http_response_helpers.ps1","maind_http_onoff_control_helpers.ps1",
    "maind_http_capability_helpers.ps1","maind_http_light_control_helpers.ps1",
    "maind_http_light_state_verification_helpers.ps1","maind_http_inventory_helpers.ps1"}, str(helpers))
check("inventory-route-boundary", "'/devices'" in inventory and "'/interaction/readAttribute'" in inventory
      and "'/interaction/invokeCommand'" not in inventory and "'/interaction/writeAttribute'" not in inventory,
      "inventory helper admits only devices/readAttribute")
check("dynamic-attribute-list", "globals['65531']" in inventory and "foreach($attr in $toRead)" in inventory,
      "ordinary attributes are derived from AttributeList")
check("endpoint-recursion", "$queue.Enqueue" in inventory and "foreach($part in $parts)" in inventory,
      "PartsList extends the pending endpoint set")
check("runtime-helper-binding", "maind_http_runtime_test_remote.sh" in controller and "ConvertFrom-LifecycleRefusal" in controller,
      "controller stages production helper and parses structured refusal")
check("no-ssh-forwarding", " -L " not in controller and "127.0.0.1:8765" in controller,
      "HTTP is executed through station-loopback wget")
codes=set(re.findall(r'PF_[A-Z0-9_]+',remote))
required={"PF_LEGACY_HTTP_TEST","PF_LEGACY_READ_VERIFY","PF_EXPERIMENT_WORKER","PF_UNRESOLVED_RUN",
          "PF_RUN_BASE_EXISTS","PF_LOCK_ACTIVE","PF_LOCK_STALE_OR_AMBIGUOUS","PF_MISSING_UTILITY",
          "PF_LISTENER_PRESENT","PF_PLATFORMD_IDENTITY"}
check("structured-preflight-codes", required<=codes, f"codes={sorted(codes)}")
check("final-clean-before-completed", remote.index("if ! clean_state") < remote.index("write_marker completed",remote.index("if ! clean_state")),
      "rollback cannot mark completion before final clean_state")
check("preactivation-no-restart", "rollback before activation boundary: platformd lifecycle skipped" in remote,
      "activation.started owns the lifecycle restart boundary")
check("run-ownership", all(token in remote for token in ("MAIND_HTTP_RUN_ID","/tmp/maind-http-runs","/tmp/maind-http-runtime.lock","marker_is_ours")),
      "per-run markers plus a global lock")
mock_codes=set(re.findall(r'PF_[A-Z0-9_]+',mock))
check("mock-preflight-alignment", {"PF_LEGACY_HTTP_TEST","PF_LEGACY_READ_VERIFY","PF_EXPERIMENT_WORKER",
      "PF_UNRESOLVED_RUN","PF_RUN_BASE_EXISTS","PF_LOCK_ACTIVE","PF_LOCK_STALE_OR_AMBIGUOUS","PF_MISSING_UTILITY"}<=mock_codes,
      f"mock_codes={sorted(mock_codes)}")
check("mock-stdin-boundary", "Binary staging is the only request that carries stdin" in launcher
      and "process.StandardInput.Close()" in launcher, "detached no-stdin commands cannot deadlock")

result={"generated_utc":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime()),"case_count":len(cases),
        "passed":sum(c["pass"] for c in cases),"all_pass":all(c["pass"] for c in cases),"cases":cases}
out=ROOT/"results"/"tests"/"inventory_production_contracts.json";out.parent.mkdir(parents=True,exist_ok=True)
out.write_text(json.dumps(result,indent=2),encoding="utf-8")
print(json.dumps(result,indent=2))
raise SystemExit(0 if result["all_pass"] else 1)

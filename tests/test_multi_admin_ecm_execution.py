from dataclasses import dataclass
import unittest
from pathlib import Path


@dataclass
class Model:
    post_claimed: bool = False
    window_open: bool = False
    fabrics: int = 1
    matter_nodes: int = 0
    rolled_back: bool = False
    clean: bool = False
    outcome: str = "not_started"

    def claim_and_post(self, http="200", complete=True, ambiguous_open=False):
        if self.post_claimed:
            raise RuntimeError("repeat forbidden")
        self.post_claimed = True  # durable claim precedes transport
        self.window_open = http == "200" or ambiguous_open
        if http != "200":
            self.outcome = "ambiguous" if ambiguous_open else f"http_{http}"
            return False
        if not complete:
            self.outcome = "incomplete_response"
            return False
        self.outcome = "window_open"
        return True

    def commission(self, result="success"):
        if result == "success":
            self.fabrics = 2
            self.matter_nodes = 1
            self.outcome = "commissioned"
        else:
            self.outcome = "matterjs_failed"

    def rollback(self, ok=True):
        self.rolled_back = ok
        self.clean = ok
        if not ok:
            self.outcome = "rollback_failed"


@dataclass
class DeadlineModel:
    elapsed: int = 0
    watchdog: int = 1500
    main_deadline: int = 1140
    rollback_deadline: int = 1380
    post_claimed: bool = False
    commission_claimed: bool = False
    rollback_claimed: bool = False
    clean: bool = False

    phase_deadlines = {
        "Preparation": 240,
        "Post": 360,
        "Commissioning": 840,
        "Readback": 1020,
        "Main": 1140,
        "Rollback": 1380,
    }

    def operation(self, phase, local_timeout, simulated_duration):
        remaining = self.phase_deadlines[phase] - self.elapsed
        if remaining <= 0:
            raise TimeoutError(f"{phase} exhausted")
        allowed = min(local_timeout, remaining)
        self.elapsed += min(simulated_duration, allowed)
        if simulated_duration > allowed:
            raise TimeoutError(f"{phase} timeout")

    def require_remaining(self, phase, required):
        if self.phase_deadlines[phase] - self.elapsed < required:
            raise TimeoutError(f"insufficient {phase} budget")

    def post(self, duration=1):
        if self.post_claimed:
            raise RuntimeError("repeat POST forbidden")
        self.post_claimed = True
        self.operation("Post", 75, duration)

    def commission(self, duration=1):
        if self.commission_claimed:
            raise RuntimeError("repeat commission forbidden")
        self.commission_claimed = True
        self.operation("Commissioning", 360, duration)

    def rollback(self, duration=1):
        if self.rollback_claimed:
            raise RuntimeError("repeat rollback transport forbidden")
        self.rollback_claimed = True
        try:
            self.operation("Rollback", 120, duration)
            self.clean = True
        except TimeoutError:
            self.clean = False
            raise

    def station_watchdog(self):
        self.elapsed = self.watchdog
        self.clean = True


class EcmExecutionTests(unittest.TestCase):
 def test_success_and_rollback_preserves_new_fabric(self):
    m = Model()
    assert m.claim_and_post()
    m.commission()
    m.rollback()
    assert (m.fabrics, m.matter_nodes, m.clean) == (2, 1, True)


 def test_http_404_and_500_are_terminal_without_retry(self):
    for status in ("404", "500"):
        m = Model()
        assert not m.claim_and_post(status)
        try:
            m.claim_and_post()
            assert False
        except RuntimeError:
            pass


 def test_incomplete_response_is_terminal(self):
    m = Model()
    assert not m.claim_and_post(complete=False)
    assert m.post_claimed and m.window_open


 def test_timeout_may_have_opened_window_but_never_retries(self):
    m = Model()
    assert not m.claim_and_post("timeout", ambiguous_open=True)
    assert m.window_open and m.outcome == "ambiguous"
    try:
        m.claim_and_post()
        assert False
    except RuntimeError:
        pass


 def test_ssh_loss_is_same_ambiguous_one_shot_boundary(self):
    m = Model()
    assert not m.claim_and_post("ssh_loss", ambiguous_open=True)
    assert m.post_claimed


 def test_matterjs_failure_leaves_yandex_fabric_untouched(self):
    m = Model()
    assert m.claim_and_post()
    m.commission("failure")
    m.rollback()
    assert (m.fabrics, m.matter_nodes, m.clean) == (1, 0, True)


 def test_watchdog_expiry_rolls_back_station_only(self):
    m = Model(window_open=True, fabrics=2, matter_nodes=1)
    m.rollback()
    assert m.fabrics == 2 and m.matter_nodes == 1 and m.clean


 def test_rollback_error_is_no_go_for_repeat(self):
    m = Model()
    m.claim_and_post()
    m.rollback(False)
    assert not m.clean and m.post_claimed


 def test_new_fabric_after_missing_expected_response_is_reconciled_not_retried(self):
    m = Model()
    m.claim_and_post("timeout", ambiguous_open=True)
    m.fabrics = 2
    m.matter_nodes = 1
    m.rollback()
    assert m.fabrics == 2 and m.post_claimed and m.clean

 def test_production_contract_is_dedicated_and_fail_closed(self):
    root = Path(__file__).resolve().parents[1]
    helper = (root / "scripts" / "maind_http_multi_admin_ecm_helpers.ps1").read_text(encoding="utf-8-sig")
    entry = (root / "scripts" / "start_maind_http_multi_admin_ecm.ps1").read_text(encoding="utf-8-sig")
    probe_entry = (root / "scripts" / "start_maind_http_multi_admin_ecm_transport_probe.ps1").read_text(encoding="utf-8-sig")
    runtime = (root / "scripts" / "start_maind_http_runtime_test.ps1").read_text(encoding="utf-8-sig")
    assert "I_APPROVE_ONE_MULTI_ADMIN_ECM_SESSION" in entry
    assert "4660" in entry and "Refusing demonstration" in entry
    assert "'/commissioning/window'" in helper
    assert "automatic retry is forbidden" in helper
    assert "Invoke-MaindEcmWindowPostSecure" in runtime
    assert "commission_with_code" in runtime and "network_only=$true" in runtime
    assert "command='get_nodes'" in runtime and "Get-MatterServerNodeCountSecure -Phase 'before'" in runtime
    assert "I_APPROVE_ONE_MULTI_ADMIN_ECM_READ_ONLY_TRANSPORT_PROBE" in probe_entry
    assert "-MultiAdminECMTransportProbeOnly" in probe_entry
    probe_marker = runtime.index("$probeRequest=Get-MaindEcmReadRequestJson")
    probe_branch = runtime[runtime.rfind("if($ecmTransportProbeOnly){", 0, probe_marker):]
    probe_branch = probe_branch[:probe_branch.index("}else{")]
    assert probe_branch.count("Invoke-RemoteLoopbackHttpRequest") == 1
    assert "Invoke-MaindEcmWindowPostSecure" not in probe_branch
    assert "commission_with_code" not in probe_branch
    for forbidden in ("RevokeCommissioning", "RemoveFabric", "factory reset"):
        assert forbidden not in helper + entry

 def test_secret_response_has_no_raw_evidence_file(self):
    root = Path(__file__).resolve().parents[1]
    runtime = (root / "scripts" / "start_maind_http_runtime_test.ps1").read_text(encoding="utf-8-sig")
    secure = runtime[runtime.index("function Invoke-MaindEcmWindowPostSecure"):runtime.index("function Invoke-MatterServerCommissionWithCodeSecure")]
    assert "Invoke-MaindNativeHttpPostTransport" in secure
    assert "Invoke-MaindTelnetHttpPostTransport" not in secure
    assert "commissioning_window_response.redacted.json" in secure
    assert "Set-Content" not in secure.split("return $window")[0].split("Get-MaindEcmRedactedSummary")[0]

 def test_phase_budgets_leave_rollback_and_watchdog_reserves(self):
    m = DeadlineModel()
    assert m.main_deadline == 1140
    assert m.rollback_deadline - m.main_deadline == 240
    assert m.watchdog - m.rollback_deadline == 120

 def test_websocket_connect_send_receive_hangs_are_bounded(self):
    for operation in ("connect", "send"):
        m = DeadlineModel(elapsed=400)
        with self.assertRaises(TimeoutError, msg=operation):
            m.operation("Commissioning", 10, 9999)
    m = DeadlineModel(elapsed=400)
    with self.assertRaises(TimeoutError):
        m.operation("Commissioning", 360, 9999)

 def test_websocket_close_hang_is_bounded_and_abortable(self):
    m = DeadlineModel(elapsed=500)
    with self.assertRaises(TimeoutError):
        m.operation("Commissioning", 5, 9999)
    assert m.elapsed == 505

 def test_ssh_unavailable_remote_hang_and_arm_hang_are_bounded(self):
    for local_timeout in (20, 45, 60):
        m = DeadlineModel()
        with self.assertRaises(TimeoutError):
            m.operation("Preparation", local_timeout, 9999)
        assert m.elapsed <= 60

 def test_post_timeout_is_ambiguous_and_never_retried(self):
    m = DeadlineModel(elapsed=250)
    with self.assertRaises(TimeoutError):
        m.post(9999)
    assert m.post_claimed
    with self.assertRaises(RuntimeError):
        m.post()

 def test_lost_matterjs_response_is_ambiguous_and_never_retried(self):
    m = DeadlineModel(elapsed=400)
    with self.assertRaises(TimeoutError):
        m.commission(9999)
    assert m.commission_claimed
    with self.assertRaises(RuntimeError):
        m.commission()

 def test_main_budget_expiry_before_post_blocks_mutation(self):
    m = DeadlineModel(elapsed=359)
    with self.assertRaises(TimeoutError):
        m.require_remaining("Post", 90)
    assert not m.post_claimed

 def test_commissioning_phase_expiry_still_allows_rollback(self):
    m = DeadlineModel(elapsed=839)
    with self.assertRaises(TimeoutError):
        m.operation("Commissioning", 370, 2)
    m.rollback(10)
    assert m.clean and m.elapsed < m.rollback_deadline

 def test_rollback_has_budget_after_main_expiry(self):
    m = DeadlineModel(elapsed=1140)
    m.rollback(120)
    assert m.clean and m.elapsed == 1260

 def test_rollback_timeout_relies_on_independent_watchdog_without_retry(self):
    m = DeadlineModel(elapsed=1300)
    with self.assertRaises(TimeoutError):
        m.rollback(9999)
    assert m.rollback_claimed and not m.clean
    with self.assertRaises(RuntimeError):
        m.rollback()
    m.station_watchdog()
    assert m.clean and m.elapsed == 1500

 def test_runtime_contract_has_no_unbounded_ecm_waits(self):
    root = Path(__file__).resolve().parents[1]
    runtime = (root / "scripts" / "start_maind_http_runtime_test.ps1").read_text(encoding="utf-8-sig")
    helper = (root / "scripts" / "maind_http_multi_admin_ecm_helpers.ps1").read_text(encoding="utf-8-sig")
    assert "CancellationToken]::None" not in runtime
    assert "Stop-ProcessTreeBounded" in runtime and "Kill($true)" in runtime
    assert "Claim-MaindEcmMatterCommission" in runtime + helper
    assert "rollback_priority" in runtime
    assert "Get-MaindEcmBoundedTimeoutMilliseconds" in runtime + helper
    assert "watchdog_safety_seconds" in helper

 def test_diagnostics_redact_pairing_secrets(self):
    root = Path(__file__).resolve().parents[1]
    helper = (root / "scripts" / "maind_http_multi_admin_ecm_helpers.ps1").read_text(encoding="utf-8-sig")
    assert "[REDACTED-MANUAL-CODE]" in helper
    assert "[REDACTED-QR-CODE]" in helper
    runtime = (root / "scripts" / "start_maind_http_runtime_test.ps1").read_text(encoding="utf-8-sig")
    assert "secret_echo_persisted=$false" in runtime


if __name__ == "__main__":
    unittest.main()

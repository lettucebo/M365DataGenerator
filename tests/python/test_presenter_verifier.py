import asyncio
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "verify_presenter", ROOT / "tests" / "live" / "verify_presenter.py"
)


@pytest.fixture
def verifier():
    module = importlib.util.module_from_spec(SPEC)
    SPEC.loader.exec_module(module)
    return module


def manifests():
    account = "presenter@example.invalid"
    url = "https://outlook.office.com/mail/known-message"
    assertion = lambda selector, expected: {"selector": selector, "expected": expected}
    checks = {
        "schemaVersion": "1.0",
        "tenantId": "11111111-1111-4111-8111-111111111111",
        "presenterUpn": account,
        "checks": [{
            "id": "mail-1", "kind": "outlookMessage", "resourceId": "known-message",
            "url": url, "account": assertion("#account", account),
            "identity": assertion("#message-id", "known-message"),
            "sender": assertion("#sender", "alice@example.invalid"),
            "content": [assertion("#decision", "Approve 12 fictional units.")],
        }],
    }
    approval = {
        "schemaVersion": "1.0", "scope": "PresenterReadOnly", "approvalId": "manual-approval-1",
        "tenantId": checks["tenantId"], "presenterUpn": account,
        "approvedUrls": [url], "requiredKinds": ["outlookMessage"],
    }
    return approval, checks


def test_scope_account_links_and_known_ids_checked_before_browser(verifier, workspace, monkeypatch):
    approval, checks = manifests()
    verifier.validate_scope(approval, checks, "manual-approval-1", checks["presenterUpn"])
    for field, value in [
        ("presenterUpn", "another@example.invalid"),
        ("scope", "RunAll"),
        ("approvedUrls", ["https://outlook.office.com/mail/another"]),
        ("requiredKinds", ["list"]),
    ]:
        bad = dict(approval, **{field: value})
        with pytest.raises(verifier.Blocked):
            verifier.validate_scope(bad, checks, "manual-approval-1", checks["presenterUpn"])
    checks["checks"][0]["identity"]["expected"] = "a-different-message"
    with pytest.raises(verifier.Blocked):
        verifier.validate_scope(approval, checks, "manual-approval-1", checks["presenterUpn"])
    calls = []

    async def forbidden_browser(*args):
        calls.append(args)
        raise AssertionError("Invalid scope must never reach the browser boundary.")

    monkeypatch.setattr(verifier, "verify_browser", forbidden_browser)
    (workspace / "approval.json").write_text(json.dumps(approval), encoding="utf-8")
    (workspace / "checks.json").write_text(json.dumps(checks), encoding="utf-8")
    report = workspace / "blocked.json"
    code = verifier.main([
        "--opt-in", "--approval", str(workspace / "approval.json"),
        "--checks", str(workspace / "checks.json"), "--approval-id", "manual-approval-1",
        "--presenter-upn", checks["presenterUpn"], "--cdp-url", "http://127.0.0.1:9222",
        "--report", str(report),
    ])
    assert code == 2 and calls == []
    assert json.loads(report.read_text(encoding="utf-8"))["reason"] == "ScopeOrEvidenceInvalid"


@pytest.mark.parametrize("url", [
    "https://outlook.office.com/mail/x?access_token=secret",
    "https://example.sharepoint.com/x?%73ig=secret",
    "https://login.microsoftonline.com/",
    "https://outlook.office.com@unapproved.invalid/",
])
def test_capability_or_login_links_never_approved(verifier, url):
    approval, checks = manifests()
    approval["approvedUrls"] = [url]
    checks["checks"][0]["url"] = url
    with pytest.raises(verifier.Blocked):
        verifier.validate_scope(approval, checks, "manual-approval-1", checks["presenterUpn"])


class Locator:
    def __init__(self, value):
        self.value = value

    async def count(self):
        return 0 if self.value is None else 1

    async def inner_text(self, **kwargs):
        return self.value

    async def is_visible(self):
        return self.value is not None


class Page:
    def __init__(self, values):
        self.values = values
        self.observed = []

    def locator(self, selector):
        self.observed.append(selector)
        return Locator(self.values.get(selector))


def test_full_message_evidence_and_wrong_sender_fail_closed(verifier):
    _, checks = manifests()
    check = checks["checks"][0]
    values = {"#account": "presenter@example.invalid", "#message-id": "known-message",
              "#sender": "alice@example.invalid", "#decision": "Approve 12 fictional units."}
    result = asyncio.run(verifier.verify_check(Page(values), check))
    assert result["status"] == "Verified"
    assert set(result["verified"]) == {"account", "identity", "sender", "content:0"}
    for selector, value in [("#sender", "bob@example.invalid"), ("#message-id", "another"),
                            ("#decision", "Reject 12 fictional units."), ("#decision", None)]:
        result = asyncio.run(verifier.verify_check(Page(dict(values, **{selector: value})), check))
        assert result["status"] == "Blocked"
        assert result["reason"] == "EvidenceMismatch"


def test_wrong_account_never_reads_message_content(verifier):
    _, checks = manifests()
    page = Page({"#account": "someone-else@example.invalid"})
    result = asyncio.run(verifier.verify_check(page, checks["checks"][0]))
    assert result["status"] == "Blocked"
    assert page.observed == ["#account"]


def test_file_list_reply_require_their_own_content_and_parent_evidence(verifier):
    approval, checks = manifests()
    check = checks["checks"][0]
    check["kind"] = "teamsMessage"
    approval["requiredKinds"] = ["teamsMessage"]
    check["url"] = "https://teams.microsoft.com/l/message/channel/known-message"
    approval["approvedUrls"] = [check["url"]]
    check["parentId"] = "known-root"
    with pytest.raises(verifier.Blocked):
        verifier.validate_scope(approval, checks, "manual-approval-1", checks["presenterUpn"])
    check["parent"] = {"selector": "#parent", "expected": "known-root"}
    verifier.validate_scope(approval, checks, "manual-approval-1", checks["presenterUpn"])
    for kind in ("file", "list", "listItem"):
        check["kind"] = kind
        approval["requiredKinds"] = [kind]
        check["content"] = []
        with pytest.raises(verifier.Blocked):
            verifier.validate_scope(approval, checks, "manual-approval-1", checks["presenterUpn"])


def test_readonly_browser_observes_only_already_open_exact_tabs_never_navigates(verifier):
    _, checks = manifests()
    page = Page({"#account": "presenter@example.invalid", "#message-id": "known-message",
                 "#sender": "alice@example.invalid", "#decision": "Approve 12 fictional units."})
    page.url = checks["checks"][0]["url"]
    unrelated = Page({})
    unrelated.url = "https://outlook.office.com/mail/another"
    context = type("Context", (), {"pages": [page, unrelated]})()
    results = asyncio.run(verifier.verify_context(context, checks))
    assert results[0]["status"] == "Verified"
    assert unrelated.observed == []
    context.pages = [unrelated]
    results = asyncio.run(verifier.verify_context(context, checks))
    assert results[0]["status"] == "Blocked"
    assert results[0]["reason"] == "ExactOpenTabRequired"
    assert unrelated.observed == []
    with pytest.raises(verifier.Blocked):
        verifier.validate_cdp("http://remote.invalid:9222")
    verifier.validate_cdp("http://127.0.0.1:9222")


def test_cli_without_opt_in_is_blocked_without_playwright_or_browser(workspace, verifier):
    output = workspace / "report.json"
    run = subprocess.run(
        [sys.executable, str(SPEC.origin), "--report", str(output)],
        capture_output=True, text=True, check=False,
    )
    assert run.returncode == 2
    report = json.loads(output.read_text(encoding="utf-8"))
    assert report["status"] == "Blocked"
    assert report["reason"] == "ExplicitOptInRequired"
    assert report["copilotStatus"] == "NotVerified"

"""Opt-in, exact-link Presenter UI checks. Never logs in, clicks, repairs, or writes M365."""

import argparse
import asyncio
import json
import re
from pathlib import Path
from urllib.parse import parse_qsl, unquote, urlsplit
from uuid import UUID

KINDS = {"outlookMessage", "teamsMessage", "file", "site", "documentLibrary", "list", "listItem", "personaPhoto"}
HOSTS = {"outlook.office.com", "outlook.office365.com", "teams.microsoft.com", "teams.cloud.microsoft"}
SENSITIVE = re.compile(r"token|secret|password|signature|^sig$|^code$|^auth|^key$", re.I)


class Blocked(ValueError):
    pass


def require(value):
    if not value:
        raise Blocked("ScopeOrEvidenceInvalid")


def fields(value, required, optional=()):
    require(isinstance(value, dict))
    require(set(required) <= value.keys() <= set(required) | set(optional))


def safe_url(url):
    require(isinstance(url, str) and 0 < len(url) <= 4096 and not re.search(r"[\x00-\x20\\]", url))
    parts = urlsplit(url)
    require(parts.scheme == "https" and not parts.username and not parts.password and parts.port in (None, 443))
    host = (parts.hostname or "").lower()
    require(host in HOSTS or host.endswith(".sharepoint.com"))
    require(not any(SENSITIVE.search(unquote(key)) for key, _ in parse_qsl(parts.query)))
    require(not SENSITIVE.search(unquote(parts.fragment).split("=")[0]) if "=" in parts.fragment else True)
    return parts


def validate_assertion(value):
    fields(value, {"selector", "expected"}, {"attribute"})
    require(isinstance(value["selector"], str) and 0 < len(value["selector"]) <= 512)
    require(value["selector"].strip().lower() not in {"*", "html", "body", ":root"})
    require(isinstance(value["expected"], str) and 0 < len(value["expected"]) <= 16000)
    if "attribute" in value:
        require(value["attribute"] in {"data-id", "data-message-id", "data-item-id", "data-resource-id",
                                        "href", "title", "aria-label", "alt", "src"})


def validate_scope(approval, manifest, approval_id, presenter):
    fields(approval, {"schemaVersion", "scope", "approvalId", "tenantId", "presenterUpn", "approvedUrls", "requiredKinds"})
    fields(manifest, {"schemaVersion", "tenantId", "presenterUpn", "checks"})
    require(approval["schemaVersion"] == manifest["schemaVersion"] == "1.0")
    require(approval["scope"] == "PresenterReadOnly" and approval["approvalId"] == approval_id and bool(approval_id))
    require(approval["tenantId"] == manifest["tenantId"])
    UUID(approval["tenantId"])
    require(approval["presenterUpn"] == manifest["presenterUpn"] == presenter and bool(presenter))
    require(isinstance(approval["approvedUrls"], list) and 0 < len(approval["approvedUrls"]) <= 100)
    require(len(set(approval["approvedUrls"])) == len(approval["approvedUrls"]))
    require(isinstance(approval["requiredKinds"], list) and bool(approval["requiredKinds"]))
    require(set(approval["requiredKinds"]) <= KINDS)
    require(isinstance(manifest["checks"], list) and 0 < len(manifest["checks"]) <= 100)
    ids = set()
    for check in manifest["checks"]:
        fields(check, {"id", "kind", "url", "resourceId", "account", "identity", "content"},
               {"sender", "parent", "parentId", "mention", "photo"})
        require(isinstance(check["id"], str) and check["id"] and check["id"] not in ids)
        ids.add(check["id"])
        require(check["kind"] in KINDS and isinstance(check["resourceId"], str) and bool(check["resourceId"]))
        safe_url(check["url"])
        validate_assertion(check["account"])
        require(check["account"]["expected"] == presenter and "attribute" not in check["account"])
        validate_assertion(check["identity"])
        require(check["identity"]["expected"] == check["resourceId"])
        require(isinstance(check["content"], list) and 0 < len(check["content"]) <= 30)
        for item in check["content"]:
            validate_assertion(item)
        if check["kind"] in {"outlookMessage", "teamsMessage"}:
            require("sender" in check)
        if "parentId" in check:
            require(isinstance(check["parentId"], str) and check["parentId"] and "parent" in check)
            require(check["parent"]["expected"] == check["parentId"])
        if check["kind"] == "personaPhoto":
            require("photo" in check)
        for key in ("sender", "parent", "mention", "photo"):
            if key in check:
                validate_assertion(check[key])
    for url in approval["approvedUrls"]:
        safe_url(url)
    require(set(approval["approvedUrls"]) == {check["url"] for check in manifest["checks"]})
    require(set(approval["requiredKinds"]) == {check["kind"] for check in manifest["checks"]})


def validate_cdp(url):
    parts = urlsplit(url)
    require(parts.scheme == "http" and parts.hostname in {"127.0.0.1", "localhost", "::1"})
    require(parts.port is not None and not parts.username and not parts.password)
    require(parts.path in ("", "/") and not parts.query and not parts.fragment)


async def assertion_matches(page, assertion):
    locator = page.locator(assertion["selector"])
    if await locator.count() != 1 or not await locator.is_visible():
        return False
    if "attribute" in assertion:
        actual = await locator.get_attribute(assertion["attribute"], timeout=5000)
    else:
        actual = await locator.inner_text(timeout=5000)
    return isinstance(actual, str) and len(actual) <= 16000 and actual.strip() == assertion["expected"]


async def verify_check(page, check):
    result = {"id": check["id"], "kind": check["kind"], "resourceId": check["resourceId"],
              "url": check["url"], "status": "Blocked", "verified": []}
    pairs = [("account", check["account"]), ("identity", check["identity"])]
    pairs += [(key, check[key]) for key in ("sender", "parent", "mention", "photo") if key in check]
    pairs += [(f"content:{index}", value) for index, value in enumerate(check["content"])]
    for name, value in pairs:
        if not await assertion_matches(page, value):
            result["reason"] = "EvidenceMismatch"
            return result
        if name == "photo":
            locator = page.locator(value["selector"])
            if not await locator.evaluate("(e) => e.tagName === 'IMG' && e.complete && e.naturalWidth > 0"):
                result["reason"] = "PhotoNotVisible"
                return result
        result["verified"].append(name)
    result["status"] = "Verified"
    return result


async def verify_context(context, manifest):
    results = []
    for check in manifest["checks"]:
        pages = [page for page in context.pages if page.url == check["url"]]
        if len(pages) != 1:
            results.append({"id": check["id"], "kind": check["kind"], "url": check["url"],
                            "status": "Blocked", "reason": "ExactOpenTabRequired", "verified": []})
            continue
        try:
            result = await verify_check(pages[0], check)
            if pages[0].url != check["url"]:
                result["status"] = "Blocked"
                result["reason"] = "PageChangedDuringVerification"
            results.append(result)
        except Exception:
            results.append({"id": check["id"], "kind": check["kind"], "url": check["url"],
                            "status": "Blocked", "reason": "BrowserOrScopeBlocked", "verified": []})
    return results


async def verify_browser(cdp_url, manifest):
    try:
        from playwright.async_api import async_playwright
    except ImportError as exc:
        raise Blocked("OptionalPlaywrightNotInstalled") from exc
    async with async_playwright() as playwright:
        browser = await playwright.chromium.connect_over_cdp(cdp_url, timeout=10000)
        require(len(browser.contexts) == 1)
        # Observe only tabs the user already opened. No goto/click/fetch/new_page/storage export.
        return await verify_context(browser.contexts[0], manifest)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--opt-in", action="store_true")
    parser.add_argument("--approval", type=Path)
    parser.add_argument("--checks", type=Path)
    parser.add_argument("--approval-id")
    parser.add_argument("--presenter-upn")
    parser.add_argument("--cdp-url")
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args(argv)
    report = {"status": "Blocked", "reason": "ExplicitOptInRequired", "checks": [],
              "copilotStatus": "NotVerified", "tenantWrites": "Prohibited"}
    try:
        require(args.opt_in)
        require(all((args.approval, args.checks, args.approval_id, args.presenter_upn, args.cdp_url)))
        approval = json.loads(args.approval.read_text(encoding="utf-8-sig"))
        manifest = json.loads(args.checks.read_text(encoding="utf-8-sig"))
        validate_scope(approval, manifest, args.approval_id, args.presenter_upn)
        validate_cdp(args.cdp_url)
        report["reason"] = "Unverified"
        report["checks"] = asyncio.run(verify_browser(args.cdp_url, manifest))
        if report["checks"] and all(item["status"] == "Verified" for item in report["checks"]):
            report["status"] = "Verified"
            report["reason"] = "ApprovedChecksOnly"
        else:
            report["reason"] = "SomeChecksBlocked"
    except Blocked as exc:
        if args.opt_in:
            report["reason"] = str(exc)
    except Exception:
        report["reason"] = "InvalidInputOrBrowserUnavailable"
    try:
        with args.report.open("x", encoding="utf-8") as stream:
            json.dump(report, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
    except OSError:
        print(json.dumps({"status": "Blocked", "reason": "ReportNotWritten"}))
        return 2
    print(json.dumps({"status": report["status"], "reason": report["reason"]}))
    return 0 if report["status"] == "Verified" else 2


if __name__ == "__main__":
    raise SystemExit(main())

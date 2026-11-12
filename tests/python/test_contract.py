import copy
import importlib.util
import json
import os
import shutil
import subprocess
import sys

import pytest
from jsonschema import Draft202012Validator, FormatChecker
from PIL import Image

from conftest import ROOT, save


def validator():
    script = ROOT / "generator" / "validate_pack.py"
    assert script.exists(), "T1 offline validator is not implemented"
    spec = importlib.util.spec_from_file_location("validate_pack", script)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def validate(workspace, documents):
    personas, scenario = documents
    save(workspace, "personas.json", personas)
    save(workspace, "scenario.json", scenario)
    return validator().validate_files(workspace / "scenario.json", workspace / "personas.json")


def test_valid_pack_and_cli(workspace, documents):
    assert validate(workspace, documents) == []
    for args in (["--personas", str(workspace / "personas.json")],
                 ["--pack", str(workspace / "scenario.json"), "--personas", str(workspace / "personas.json")]):
        result = subprocess.run([sys.executable, str(ROOT / "generator" / "validate_pack.py"), *args],
                                capture_output=True, text=True)
        assert result.returncode == 0, result.stdout + result.stderr
        assert json.loads(result.stdout) == {"valid": True, "errors": []}


@pytest.mark.parametrize("target,path", [
    ("personas", ("people", 0)), ("personas", ("avatarAssets", 0, "rights")),
    ("scenario", ("outlook", "threads", 0, "messages", 0)),
    ("scenario", ("teams", "channels", 0, "messages", 0, "mentions", 0)),
    ("scenario", ("workbooks", 0, "sheets", 0, "columns", 0)),
    ("scenario", ("sharepoint", "sites", 0, "lists", 0, "columns", 0)),
])
def test_nested_unknown_fields_rejected(workspace, documents, target, path):
    node = documents[0 if target == "personas" else 1]
    for part in path:
        node = node[part]
    node["unexpected"] = True
    assert any(e["code"] == "schema" for e in validate(workspace, documents))


@pytest.mark.parametrize("mutation", [
    lambda p, s: p["people"][0].update(upn="private@example.invalid"),
    lambda p, s: p["people"][0].update(managerRef="bob"),
    lambda p, s: p["people"][0].update(managerRef="missing"),
    lambda p, s: p["people"][1].update(alias="ALICE"),
    lambda p, s: p["people"][1].update(avatarAssetId="alice-photo"),
    lambda p, s: p["avatarAssets"][1].update(sha256=p["avatarAssets"][0]["sha256"], path="alice.jpg"),
    lambda p, s: s["roles"].update(Presenter=s["roles"]["Lead"]),
    lambda p, s: s["roles"]["Analyst"].update(personaId="alice"),
    lambda p, s: s["roles"]["Lead"].update(personaId="missing"),
    lambda p, s: s["roles"]["Lead"].update(businessUnitId="missing"),
    lambda p, s: s["scenario"].update(personaPackId="wrong"),
    lambda p, s: s["scenario"].update(timeZone="Not/AZone"),
    lambda p, s: s["scenario"].update(anchorDate="2026-02-31"),
    lambda p, s: s["outlook"]["threads"][0]["messages"][0].update(action="reply"),
    lambda p, s: s["outlook"]["threads"][0]["messages"][1].update(fromRole="Lead"),
    lambda p, s: s["outlook"]["threads"][0]["messages"][1].update(parentId="unknown"),
    lambda p, s: s["outlook"]["threads"][0]["messages"][0].update(ccRoles=[]),
    lambda p, s: s["teams"]["channels"][0]["messages"][0].update(fromRole="Presenter"),
    lambda p, s: s["teams"]["channels"][0]["messages"][0].update(mentions=[]),
    lambda p, s: s["teams"]["channels"][0]["messages"][0]["mentions"][0].update(text="Someone else"),
    lambda p, s: s["teams"]["channels"][0]["messages"][0].update(createdDateTime="2026-11-01T10:00:00+08:00"),
    lambda p, s: s["teams"]["channels"][0]["messages"][0]["replies"][0].update(createdDateTime="2026-10-28T10:00:00+08:00"),
    lambda p, s: s["teams"]["channels"][0]["messages"][0]["replies"][0].update(id="post"),
    lambda p, s: s["assets"][0].update(workbookId="missing"),
    lambda p, s: s["outlook"]["threads"][0]["messages"][0].update(bodyHtml="<p>{{asset:unknown}}</p>"),
    lambda p, s: s["outlook"]["threads"][0]["messages"][0].update(assetRefs=[]),
    lambda p, s: s["sharepoint"]["sites"][0]["lists"][0]["items"][0]["values"].update(done="false"),
    lambda p, s: s["sharepoint"]["sites"][0]["lists"][0]["items"][0]["values"].update(extra=1),
    lambda p, s: s["sharepoint"]["sites"][0]["lists"][0]["items"][0].update(values={"title": "Missing"}),
    lambda p, s: s["workbooks"][0]["sheets"][0]["rows"][0].__setitem__(1, "wrong"),
    lambda p, s: s["workbooks"][0]["sheets"][0]["columns"][0].update(formula="=1"),
    lambda p, s: s["workbooks"][0]["sheets"][0].update(generate={"seed": 1}),
])
def test_semantic_rejections(workspace, documents, mutation):
    mutation(*documents)
    errors = validate(workspace, documents)
    assert errors
    assert all(set(e) == {"path", "code", "message", "remediation"} for e in errors)


@pytest.mark.parametrize("html", [
    "<script>alert(1)</script>", "<p onclick=\"x()\">x</p>", "<img src=\"x\">",
    "<a href=\"javascript:alert(1)\">x</a>", "<a href=\"data:text/plain,x\">x</a>",
    "<a href=\"//example.invalid\">x</a>", "<p><strong>unclosed</p>",
])
def test_unsafe_html(workspace, documents, html):
    documents[1]["outlook"]["threads"][0]["messages"][0]["bodyHtml"] = html
    assert validate(workspace, documents)


@pytest.mark.parametrize("path", ["..\\alice.jpg", "/alice.jpg", "C:\\alice.jpg", "\\\\host\\x.jpg",
                                  "sub\\..\\alice.jpg", "alice.jpg:stream", "https://x/a.jpg"])
def test_unsafe_avatar_path(workspace, documents, path):
    documents[0]["avatarAssets"][0]["path"] = path
    assert validate(workspace, documents)


def test_jpeg_hash_decode_and_limit(workspace, documents):
    avatar = workspace / "alice.jpg"
    avatar.write_bytes(b"not a jpeg")
    assert validate(workspace, documents)
    avatar.write_bytes(b"x" * (4 * 1024 * 1024 + 1))
    assert any(e["code"] == "avatar" for e in validate(workspace, documents))


def test_duplicate_destination_and_no_workload(workspace, documents):
    documents[1]["assets"].append({**documents[1]["assets"][0], "id": "duplicate"})
    assert validate(workspace, documents)
    documents[1]["assets"].pop()
    for key in ("outlook", "teams", "onedrive", "sharepoint"):
        documents[1].pop(key)
    assert validate(workspace, documents)


def test_cli_structured_failure(workspace, documents):
    documents[0]["password"] = "not-allowed"
    save(workspace, "personas.json", documents[0])
    script = ROOT / "generator" / "validate_pack.py"
    assert script.exists(), "T1 validator is not implemented"
    result = subprocess.run([sys.executable, str(script), "--personas", str(workspace / "personas.json")],
                            capture_output=True, text=True)
    assert result.returncode == 2
    assert json.loads(result.stdout)["errors"][0]["remediation"]


def test_all_five_schemas_and_private_example():
    for name in ("personas", "scenario", "config", "persona-binding", "run-state"):
        path = ROOT / "schemas" / f"{name}.schema.json"
        assert path.exists(), f"T1 schema missing: {name}"
        schema = json.loads(path.read_text(encoding="utf-8"))
        Draft202012Validator.check_schema(schema)
        assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
    schema = json.loads((ROOT / "schemas" / "config.schema.json").read_text())
    example = json.loads((ROOT / "config.json.example").read_text())
    Draft202012Validator(schema).validate(example)
    example["clientSecret"] = "forbidden"
    assert list(Draft202012Validator(schema).iter_errors(example))


def test_run_state_completion_requires_verified_results():
    path = ROOT / "schemas" / "run-state.schema.json"
    assert path.exists(), "T1 run-state contract missing"
    schema = json.loads(path.read_text())
    record = {
        "schemaVersion": "1.0", "runId": "test", "fingerprint": "a" * 64,
        "context": {"tenantId": "11111111-1111-4111-8111-111111111111",
                    "clientId": "22222222-2222-4222-8222-222222222222", "scenarioId": "test",
                    "personaPackId": "fixture", "personaPackFingerprint": "b" * 64,
                    "instanceId": "test", "bindingFingerprint": "c" * 64,
                    "preparedFingerprint": "d" * 64, "presenterUpn": "presenter@example.invalid"},
        "status": "Completed", "events": [], "results": [
            {"id": "mail-1", "workload": "outlook", "status": "Verified",
             "objectId": "remote-id", "evidence": {"verifiedAt": "2026-10-30T00:00:00Z", "method": "ReadBack", "sha256": "e" * 64}}
        ]
    }
    check = Draft202012Validator(schema)
    assert not list(check.iter_errors(record))
    for status in ("Partial", "Unknown", "Submitted"):
        bad = copy.deepcopy(record)
        bad["results"][0]["status"] = status
        assert list(check.iter_errors(bad))


def test_cli_argument_errors_are_structured():
    script = ROOT / "generator" / "validate_pack.py"
    result = subprocess.run([sys.executable, str(script)], capture_output=True, text=True)
    assert result.returncode == 2
    response = json.loads(result.stdout)
    assert response["valid"] is False
    assert set(response["errors"][0]) == {"path", "code", "message", "remediation"}


def test_numeric_overflow_is_validation_error(workspace, documents):
    documents[1]["workbooks"][0]["sheets"][0]["rows"][0][1] = 10 ** 400
    assert validate(workspace, documents)


@pytest.mark.parametrize("target", ["column", "formula"])
def test_recipe_xml_controls_rejected_before_build(workspace, documents, target):
    sheet = documents[1]["workbooks"][0]["sheets"][0]
    if target == "column":
        sheet["columns"][0]["name"] = "Bad\x01Header"
    else:
        sheet["columns"][2]["formula"] = "=1+\x01"
    assert validate(workspace, documents)


@pytest.mark.parametrize("html", ["<script", "<p>text<img src=x</p>", "<p>text</p><!broken"])
def test_malformed_html_markup_rejected(workspace, documents, html):
    documents[1]["outlook"]["threads"][0]["messages"][0]["bodyHtml"] = html
    assert validate(workspace, documents)


def test_safe_html_entities_tables_and_links(workspace, documents):
    documents[1]["outlook"]["threads"][0]["messages"][0]["bodyHtml"] = (
        '<p>Values &lt; 10 &amp; &gt; 0.</p><table><tbody><tr><th>Label</th>'
        '<td><em>Test</em></td></tr></tbody></table><a href="{{asset:metrics}}">Metrics</a>'
        '<a href="https://example.invalid/docs">Docs</a>'
    )
    assert validate(workspace, documents) == []


def test_reparse_directory_rejected(workspace, documents):
    real, linked = workspace / "real", workspace / "linked"
    real.mkdir()
    shutil.copyfile(workspace / "alice.jpg", real / "alice.jpg")
    if os.name == "nt":
        result = subprocess.run(["cmd.exe", "/c", "mklink", "/J", str(linked), str(real)],
                                capture_output=True, text=True)
        assert result.returncode == 0, result.stdout + result.stderr
    else:
        linked.symlink_to(real, target_is_directory=True)
    documents[0]["avatarAssets"][0]["path"] = "linked\\alice.jpg"
    assert any(e["code"] == "avatar" for e in validate(workspace, documents))


def test_jpeg_decoded_dimension_limit(workspace, documents):
    Image.new("RGB", (8193, 1)).save(workspace / "alice.jpg", "JPEG")
    assert any("decoding limits" in e["message"] for e in validate(workspace, documents))


def test_local_asset_real_type_and_hash(workspace, documents):
    from hashlib import sha256
    path = workspace / "notes.txt"
    path.write_text("Fictional test data.", encoding="utf-8")
    asset = documents[1]["assets"][0]
    asset.pop("workbookId")
    documents[1].pop("workbooks")
    asset.update(localPath="notes.txt", sha256=sha256(path.read_bytes()).hexdigest(), mediaType="text/plain")
    asset["destination"]["name"] = "Notes.txt"
    assert validate(workspace, documents) == []
    path.write_bytes(b"\x00not-text")
    assert validate(workspace, documents)
    asset.update(localPath="fake.xlsx", mediaType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
    asset["destination"]["name"] = "Fake.xlsx"
    (workspace / "fake.xlsx").write_bytes(b"not an Office file")
    assert validate(workspace, documents)


def test_cross_parent_teams_ids_and_list_choices(workspace, documents):
    import copy
    post = documents[1]["teams"]["channels"][0]["messages"][0]
    duplicate = copy.deepcopy(post)
    duplicate.update(id="second-post", createdDateTime="2026-10-29T12:00:00+08:00")
    duplicate["replies"][0]["createdDateTime"] = "2026-10-29T13:00:00+08:00"
    documents[1]["teams"]["channels"][0]["messages"].append(duplicate)
    assert any(e["code"] == "duplicate" for e in validate(workspace, documents))
    documents[1]["teams"]["channels"][0]["messages"].pop()
    listing = documents[1]["sharepoint"]["sites"][0]["lists"][0]
    listing["columns"][1] = {"id": "done", "name": "Status", "type": "choice", "choices": ["Open", "Closed"]}
    listing["items"][0]["values"]["done"] = "Unlisted"
    assert any(e["code"] == "list-type" for e in validate(workspace, documents))


def test_private_binding_nested_evidence_is_strict():
    schema = json.loads((ROOT / "schemas" / "persona-binding.schema.json").read_text())
    guid, digest = "11111111-1111-4111-8111-111111111111", "a" * 64
    timestamp = "2026-10-30T00:00:00Z"
    user = {
        "objectId": guid, "upn": "test@example.invalid", "status": "Provisioned", "serviceStatus": "NotVerified",
        "profile": {"sha256": digest, "verifiedAt": timestamp, "displayName": "Test", "jobTitle": "Test",
                    "department": "Test", "companyName": "Test", "officeLocation": "Test",
                    "managerObjectId": None, "usageLocation": "TW"},
        "photo": {"avatarAssetId": "test-photo", "sourceSha256": digest, "verifiedSha256": digest, "verifiedAt": timestamp},
        "license": {"profileId": "standard", "skuIds": [guid], "verifiedAt": timestamp}
    }
    binding = {"tenantId": guid, "packId": "test", "version": "1.0", "fingerprint": digest,
               "instanceId": "test", "users": {"test": user}, "status": "Provisioned", "serviceStatus": "NotVerified"}
    check = Draft202012Validator(schema)
    assert not list(check.iter_errors(binding))
    user["photo"]["accessToken"] = "not-allowed"
    assert list(check.iter_errors(binding))
    user["photo"].pop("accessToken")
    user["serviceStatus"] = "Verified"
    assert list(check.iter_errors(binding))


def test_identical_decoded_portraits_with_different_metadata_rejected(workspace, documents):
    from hashlib import sha256
    data = (workspace / "alice.jpg").read_bytes()
    comment = b"different JPEG metadata, same portrait"
    data = data[:2] + b"\xff\xfe" + (len(comment) + 2).to_bytes(2, "big") + comment + data[2:]
    (workspace / "bob.jpg").write_bytes(data)
    documents[0]["avatarAssets"][1]["sha256"] = sha256(data).hexdigest()
    assert any(e["code"] == "duplicate" for e in validate(workspace, documents))


def test_office_asset_requires_decodable_main_part(workspace, documents):
    from hashlib import sha256
    from zipfile import ZipFile
    asset = documents[1]["assets"][0]
    asset.pop("workbookId")
    documents[1].pop("workbooks")
    path = workspace / "spoof.xlsx"
    with ZipFile(path, "w") as archive:
        archive.writestr("[Content_Types].xml",
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
            '<Override PartName="/xl/workbook.xml" '
            'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/></Types>')
        archive.writestr("xl/workbook.xml", "not a workbook")
    asset.update(localPath="spoof.xlsx", sha256=sha256(path.read_bytes()).hexdigest())
    assert any(e["code"] == "asset" for e in validate(workspace, documents))


@pytest.mark.parametrize("collision", ["same-owner", "file-as-folder"])
def test_physical_upload_destinations_do_not_alias(workspace, documents, collision):
    duplicate = copy.deepcopy(documents[1]["assets"][0])
    duplicate["id"] = "other-metrics"
    if collision == "same-owner":
        duplicate["destination"]["containerId"] = "second-drive"
        documents[1]["onedrive"]["drives"].append({
            "id": "second-drive", "ownerRole": "Lead", "assetRefs": ["other-metrics"]
        })
    else:
        duplicate["destination"]["folder"] = "Training\\Metrics.xlsx"
        duplicate["destination"]["name"] = "Other.xlsx"
        documents[1]["onedrive"]["drives"][0]["assetRefs"].append("other-metrics")
    documents[1]["assets"].append(duplicate)
    assert validate(workspace, documents)


def existing_documents(workspace):
    return json.loads((workspace / "existing-personas.json").read_text(encoding="utf-8"))


def validate_existing(workspace, pack, with_scenario=False):
    save(workspace, "existing-personas.json", pack)
    scenario = workspace / "scenario.json" if with_scenario else None
    return validator().validate_files(scenario, workspace / "existing-personas.json")


def test_existing_pack_needs_no_portraits_or_license_profiles(workspace):
    isolated = workspace / "isolated"
    isolated.mkdir()
    shutil.copyfile(workspace / "existing-personas.json", isolated / "personas.json")
    shutil.copyfile(workspace / "scenario.json", isolated / "scenario.json")
    assert validator().validate_files(None, isolated / "personas.json") == []
    assert validator().validate_files(isolated / "scenario.json", isolated / "personas.json") == []
    result = subprocess.run([sys.executable, str(ROOT / "generator" / "validate_pack.py"), "--pack", str(isolated / "scenario.json"),
                             "--personas", str(isolated / "personas.json")], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
    assert json.loads(result.stdout) == {"valid": True, "errors": []}
    managed = workspace / "managed-isolated"
    managed.mkdir()
    shutil.copyfile(workspace / "personas.json", managed / "personas.json")
    assert any(e["code"] == "avatar" for e in validator().validate_files(None, managed / "personas.json"))


def test_existing_manager_omitted_or_null_means_keep_and_is_valid(workspace):
    pack = existing_documents(workspace)
    assert "managerRef" not in pack["people"][0]
    assert validate_existing(workspace, pack) == []
    pack["people"][0]["managerRef"] = None
    assert validate_existing(workspace, pack) == []
    pack["people"][1].pop("managerRef")
    pack["people"][0].pop("profile")
    pack["people"][0].pop("identityHint")
    assert validate_existing(workspace, pack) == []


@pytest.mark.parametrize("mutation", [
    lambda p: p.update(avatarAssets=[]),
    lambda p: p.update(password="forbidden"),
    lambda p: p["people"][0].update(avatarAssetId="alice-photo"),
    lambda p: p["people"][0].update(licenseProfile="standard"),
    lambda p: p["people"][0].update(alias="alice"),
    lambda p: p["people"][0].update(displayName="Alice Test"),
    lambda p: p["people"][0].update(upn="private@example.invalid"),
    lambda p: p["people"][0].update(objectId="11111111-1111-4111-8111-111111111111"),
    lambda p: p["people"][0]["identityHint"].update(upn="private@example.invalid"),
    lambda p: p["people"][0]["identityHint"].update(alias="alice@example.invalid"),
    lambda p: p["people"][0]["identityHint"].update(displayName="private@example.invalid"),
    lambda p: p["people"][0]["identityHint"].update(displayName="11111111-1111-4111-8111-111111111111"),
    lambda p: p["people"][0].update(identityHint={}),
    lambda p: p["people"][0]["profile"].update(displayName="Changed"),
    lambda p: p["people"][0]["profile"].update(usageLocation="TW"),
    lambda p: p["people"][0]["profile"].update(jobTitle=""),
    lambda p: p["people"][0]["profile"].update(jobTitle=None),
    lambda p: p["people"][0]["profile"].update(officeLocation="   "),
    lambda p: p["people"][0]["profile"].update(department="bad\ncontrol"),
    lambda p: p["people"][0].update(profile={}),
    lambda p: p["people"][1].update(managerRef="bob"),
    lambda p: p["people"][1].update(managerRef="missing"),
    lambda p: p["people"][0].update(managerRef="bob"),
    lambda p: p["people"][1].update(personaId="alice"),
    lambda p: p["people"][1]["identityHint"].update(alias="ALICE"),
    lambda p: p["people"][0]["profile"].update(companyName="Another Company"),
    lambda p: p.update(version="1.0"),
    lambda p: p.pop("accountSource"),
    lambda p: p.update(accountSource="Managed"),
])
def test_existing_pack_rejections(workspace, mutation):
    pack = existing_documents(workspace)
    mutation(pack)
    errors = validate_existing(workspace, pack)
    assert errors
    assert all(set(e) == {"path", "code", "message", "remediation"} for e in errors)


def test_managed_pack_rejects_existing_only_fields(workspace, documents):
    documents[0]["accountSource"] = "Existing"
    assert validate(workspace, documents)
    documents[0].pop("accountSource")
    documents[0]["people"][0]["identityHint"] = {"alias": "alice"}
    assert validate(workspace, documents)
    documents[0]["people"][0].pop("identityHint")
    documents[0]["people"][0]["profile"] = {"jobTitle": "Lead"}
    assert validate(workspace, documents)


def valid_existing_config():
    return {
        "schemaVersion": "1.1", "tenantId": "11111111-1111-4111-8111-111111111111", "presenterUpn": "presenter@example.invalid",
        "clientId": "22222222-2222-4222-8222-222222222222",
        "clientSecretEnvironmentVariable": "M365_DEMO_CLIENT_SECRET",
        "personas": {"accountSource": "Existing", "packPath": "personas\\m365-sample\\personas.json", "instanceId": "demo-company",
                     "bindingPath": "private\\demo.binding.json",
                     "accountMappings": {"adele-vance": "selected-1@example.invalid", "megan-bowen": "selected-2@example.invalid"}},
    }


def test_config_sources_are_versioned_and_never_mixed():
    schema = json.loads((ROOT / "schemas" / "config.schema.json").read_text())
    check = Draft202012Validator(schema)
    managed = json.loads((ROOT / "tests" / "fixtures" / "managed-config.json").read_text())
    assert not list(check.iter_errors(managed)), "Managed 1.0 compatibility must remain"
    assert not list(check.iter_errors(valid_existing_config()))
    assert not list(check.iter_errors(json.loads((ROOT / "config.json.example").read_text()))), "Root example is the public Existing form"
    assert json.loads((ROOT / "config.json.example").read_text())["personas"]["accountSource"] == "Existing"
    mutations = [
        lambda c: c["personas"].pop("accountMappings"),
        lambda c: c["personas"].update(accountMappings={}),
        lambda c: c["personas"].update(accountMappings={"Bad Key": "selected-1@example.invalid"}),
        lambda c: c["personas"].update(accountMappings={"adele-vance": "not-a-upn"}),
        lambda c: c["personas"].update(accountPrefix="demo-"),
        lambda c: c["personas"].update(userDomain="example.invalid"),
        lambda c: c["personas"].update(usageLocation="TW"),
        lambda c: c["personas"].update(licenseProfiles={"standard": {"skuIds": ["33333333-3333-4333-8333-333333333333"]}}),
        lambda c: c["personas"].update(accountSource="Managed"),
        lambda c: c["personas"].pop("accountSource"),
        lambda c: c.update(schemaVersion="1.0"),
        lambda c: c.update(clientSecret="forbidden"),
        lambda c: c.update(schemaVersion="2.0"),
    ]
    for mutate in mutations:
        config = copy.deepcopy(valid_existing_config())
        mutate(config)
        assert list(check.iter_errors(config))
    for mutate in (lambda c: c["personas"].update(accountSource="Existing"), lambda c: c["personas"].update(accountMappings={"a": "a@example.invalid"})):
        config = copy.deepcopy(managed)
        mutate(config)
        assert list(check.iter_errors(config)), "A 1.0 config cannot carry the Existing source"


def existing_binding():
    guid, digest, timestamp = "11111111-1111-4111-8111-111111111111", "a" * 64, "2026-11-07T00:00:00Z"
    user = {
        "objectId": guid, "upn": "selected-1@example.invalid", "status": "ConfiguredExisting", "serviceStatus": "NotVerified", "source": "BindExisting",
        "profile": {"sha256": digest, "verifiedAt": timestamp, "displayName": "Existing Person", "jobTitle": "Lead", "department": None,
                    "companyName": "", "officeLocation": None, "managerObjectId": None, "usageLocation": None},
    }
    return {"tenantId": guid, "packId": "m365-sample", "version": "1.1", "accountSource": "Existing", "fingerprint": digest,
            "instanceId": "demo-company", "status": "ConfiguredExisting", "serviceStatus": "NotVerified",
            "approval": {"planFingerprint": digest, "demoAccountAcknowledged": True, "journalFingerprint": digest, "acknowledgedAt": timestamp},
            "users": {"adele-vance": user}}


def test_existing_binding_allows_actual_nullable_snapshot_but_never_fakes_provisioned():
    schema = json.loads((ROOT / "schemas" / "persona-binding.schema.json").read_text())
    check = Draft202012Validator(schema, format_checker=FormatChecker())
    assert not list(check.iter_errors(existing_binding()))
    mutations = [
        lambda b: b.update(status="Provisioned"),
        lambda b: b.update(version="1.0"),
        lambda b: b.update(serviceStatus="Verified"),
        lambda b: b.pop("approval"),
        lambda b: b["approval"].update(demoAccountAcknowledged=False),
        lambda b: b["approval"].pop("journalFingerprint"),
        lambda b: b["users"]["adele-vance"].update(status="Provisioned"),
        lambda b: b["users"]["adele-vance"].update(source="Create"),
        lambda b: b["users"]["adele-vance"].pop("source"),
        lambda b: b["users"]["adele-vance"].update(photo={"avatarAssetId": "x", "sourceSha256": "a" * 64, "verifiedSha256": "a" * 64, "verifiedAt": "2026-11-07T00:00:00Z"}),
        lambda b: b["users"]["adele-vance"].update(license={"profileId": "standard", "skuIds": ["11111111-1111-4111-8111-111111111111"], "verifiedAt": "2026-11-07T00:00:00Z"}),
        lambda b: b["users"]["adele-vance"]["profile"].pop("officeLocation"),
        lambda b: b["users"]["adele-vance"]["profile"].update(displayName=None),
        lambda b: b["users"]["adele-vance"]["profile"].update(jobTitle=7),
        lambda b: b["users"]["adele-vance"]["profile"].update(usageLocation="tw"),
        lambda b: b["users"]["adele-vance"]["profile"].update(managerObjectId="not-a-guid"),
    ]
    for mutate in mutations:
        binding = copy.deepcopy(existing_binding())
        mutate(binding)
        assert list(check.iter_errors(binding))
    for value in ("", "TW", None):
        binding = existing_binding()
        binding["users"]["adele-vance"]["profile"]["usageLocation"] = value
        assert not list(check.iter_errors(binding))


PUBLISHED_PAIRS = [("rich-training", "company-24"), ("minimal", "company-24"), ("sample-rich", "m365-sample"),
                   ("sample-minimal", "m365-sample"), ("existing-minimal", "existing-template")]


@pytest.mark.parametrize("example,pack", PUBLISHED_PAIRS)
def test_published_scenarios_validate_against_their_own_persona_pack(example, pack):
    errors = validator().validate_files(ROOT / "examples" / example / "scenario.json", ROOT / "personas" / pack / "personas.json")
    assert errors == []


OFFICIAL_SAMPLE_NAMES = sorted([
    "Adele Vance", "Alex Wilber", "Diego Siciliani", "Grady Archie", "Henrietta Mueller", "Isaiah Langer", "Johanna Lorenz",
    "Joni Sherman", "Lee Gu", "Lidia Holloway", "Lynne Robbins", "Megan Bowen", "Miriam Graham", "Nestor Wilke",
    "Patti Fernandez", "Pradeep Gupta"])


def public_pack(name):
    return json.loads((ROOT / "personas" / name / "personas.json").read_text(encoding="utf-8"))


def test_sample_and_generic_packs_are_hints_only_and_default_subsets_are_self_contained():
    sample, generic = public_pack("m365-sample"), public_pack("existing-template")
    assert sorted(p["identityHint"]["displayName"] for p in sample["people"]) == OFFICIAL_SAMPLE_NAMES
    for pack in (sample, generic):
        text = json.dumps(pack)
        assert pack["accountSource"] == "Existing" and "@" not in text and "avatar" not in text and "license" not in text.lower()
        assert not [f for f in (ROOT / "personas" / pack["packId"]).iterdir() if f.suffix.lower() in (".jpg", ".jpeg", ".png")]
    assert all("identityHint" not in p for p in generic["people"]) and len(generic["people"]) == 3
    for pack, subset in ((sample, {"adele-vance", "alex-wilber", "megan-bowen"}), (generic, {p["personaId"] for p in generic["people"]})):
        by_id = {p["personaId"]: p for p in pack["people"]}
        for persona in subset:
            assert by_id[persona].get("managerRef") in subset | {None}
    config = json.loads((ROOT / "config.json.example").read_text(encoding="utf-8"))
    assert set(config["personas"]["accountMappings"]) == {"adele-vance", "alex-wilber", "megan-bowen"}
    assert all(value.endswith("@example.invalid") for value in config["personas"]["accountMappings"].values())


def scenario_scope(document):
    teams = [m for c in document["teams"]["channels"] for p in c["messages"] for m in [p, *p["replies"]]]
    mails = [m for t in document["outlook"]["threads"] for m in t["messages"]]
    authors = {m["fromRole"] for m in [*mails, *teams]}
    return {"stories": len(document["stories"]), "mails": len(mails), "teams": len(teams), "authors": len(authors), "assets": len(document["assets"]),
            "sheets": [len(s["columns"]) for b in document["workbooks"] for s in b["sheets"]],
            "lists": [len(l["items"]) for s in document["sharepoint"]["sites"] for l in s["lists"]]}


def test_sample_rich_keeps_the_original_story_scope_with_sample_authors_only():
    rich = json.loads((ROOT / "examples" / "rich-training" / "scenario.json").read_text(encoding="utf-8"))
    sample = json.loads((ROOT / "examples" / "sample-rich" / "scenario.json").read_text(encoding="utf-8"))
    assert scenario_scope(sample) == scenario_scope(rich)
    assert sample["scenario"]["personaPackId"] == "m365-sample"
    persona_ids = {p["personaId"] for p in public_pack("m365-sample")["people"]}
    assert {r["personaId"] for r in sample["roles"].values()} <= persona_ids
    company = {p["displayName"] for p in public_pack("company-24")["people"]}
    text = json.dumps(sample, ensure_ascii=False)
    assert not [name for name in company if name in text]


def test_sample_rich_title_is_a_natural_visible_team_name():
    title = json.loads((ROOT / "examples" / "sample-rich" / "scenario.json").read_text(encoding="utf-8"))["scenario"]["title"]
    assert title and title == title.strip() and len(title) <= 200
    assert not [word for word in ("demo", "sample", "fictional", "虛構", "示範", "範例", "人物版") if word in title.casefold()]

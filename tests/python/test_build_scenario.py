import importlib.util
import json
import subprocess
import sys
from pathlib import Path
from zipfile import ZipFile

import pytest
from openpyxl import load_workbook

from conftest import ROOT, save


def builder():
    path = ROOT / "generator" / "build_scenario.py"
    assert path.exists(), "T1 deterministic builder is not implemented"
    spec = importlib.util.spec_from_file_location("build_scenario", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def build(workspace, output):
    return builder().build_scenario(workspace / "scenario.json", workspace / "personas.json", output)


def bytes_in(root):
    return {str(p.relative_to(root)): p.read_bytes() for p in root.rglob("*") if p.is_file()}


def test_deterministic_reuse_and_literal_strings(workspace):
    first, second = workspace / "first", workspace / "second"
    build(workspace, first)
    build(workspace, second)
    assert bytes_in(first) == bytes_in(second)
    manifest = json.loads((first / "prepared-manifest.json").read_text())
    assert manifest["schemaVersion"] == "1.0"
    assert manifest["builderVersion"] == "1.0.0"
    assert len(manifest["fingerprint"]) == 64
    assert (first / "COMPLETE.json").exists()
    assert not list(first.rglob("*.ps1"))
    book = load_workbook(first / "assets" / "metrics.xlsx")
    assert book["Data"]["A2"].value == "=not-a-formula"
    assert book["Data"]["A2"].data_type == "s"
    assert book["Data"]["C2"].value == "=B2*2"
    assert book["Data"]["C2"].data_type == "f"
    before = bytes_in(first)
    build(workspace, first)
    assert bytes_in(first) == before
    (first / "assets" / "metrics.xlsx").write_bytes(b"tampered")
    with pytest.raises(ValueError):
        build(workspace, first)
    assert (first / "assets" / "metrics.xlsx").read_bytes() == b"tampered"


def test_prepared_workbook_has_no_fixed_description_and_stays_byte_deterministic(workspace):
    first, second = workspace / "first", workspace / "second"
    build(workspace, first)
    build(workspace, second)
    path = first / "assets" / "metrics.xlsx"
    assert path.read_bytes() == (second / "assets" / "metrics.xlsx").read_bytes()
    assert load_workbook(path).properties.description is None
    with ZipFile(path) as archive:
        core = archive.read("docProps/core.xml").decode("utf-8")
    assert "description" not in core and "Fictional" not in core


def test_incomplete_or_extra_existing_output_never_overwritten(workspace):
    target = workspace / "out"
    target.mkdir()
    with pytest.raises(ValueError):
        build(workspace, target)
    assert list(target.iterdir()) == []
    target.rmdir()
    build(workspace, target)
    (target / "extra.txt").write_text("extra")
    with pytest.raises(ValueError):
        build(workspace, target)


def test_invalid_recipe_leaves_no_output(workspace, documents):
    documents[1]["workbooks"][0]["sheets"][0]["rows"][0] = ["wrong width"]
    save(workspace, "scenario.json", documents[1])
    target = workspace / "out"
    with pytest.raises(ValueError):
        build(workspace, target)
    assert not target.exists()


def test_input_change_blocks_reuse(workspace, documents):
    target = workspace / "out"
    build(workspace, target)
    before = bytes_in(target)
    documents[1]["scenario"]["title"] = "Changed"
    save(workspace, "scenario.json", documents[1])
    with pytest.raises(ValueError):
        build(workspace, target)
    assert bytes_in(target) == before


def test_generator_recipe(workspace, documents):
    sheet = documents[1]["workbooks"][0]["sheets"][0]
    sheet["columns"] = [{"name": "Region", "type": "string"}, {"name": "Period", "type": "string"}, {"name": "Sales", "type": "integer"}]
    sheet.pop("rows")
    sheet["generate"] = {"seed": 42, "dimensions": ["North"], "periods": ["Q1", "Q2"],
                         "min": 1, "max": 10, "overrides": [{"dimension": "North", "period": "Q2", "value": 99}]}
    save(workspace, "scenario.json", documents[1])
    build(workspace, workspace / "out")
    book = load_workbook(workspace / "out" / "assets" / "metrics.xlsx")
    assert book["Data"]["C3"].value == 99


def test_local_asset_prepared_pack_is_self_contained(workspace, documents):
    from hashlib import sha256
    content = b"Fictional local source."
    (workspace / "source.txt").write_bytes(content)
    asset = documents[1]["assets"][0]
    asset.pop("workbookId")
    asset.update(localPath="source.txt", sha256=sha256(content).hexdigest(), mediaType="text/plain")
    asset["destination"]["name"] = "Source.txt"
    documents[1].pop("workbooks")
    save(workspace, "scenario.json", documents[1])
    target = workspace / "out"
    build(workspace, target)
    (workspace / "source.txt").unlink()
    from generator.validate_pack import validate_files
    assert validate_files(target / "scenario.json", target / "personas" / "personas.json") == []
    assert (target / "assets" / "metrics.txt").read_bytes() == content


def test_builder_cli_success_reuse_and_failure(workspace, documents):
    script = ROOT / "generator" / "build_scenario.py"
    target = workspace / "out"
    args = [sys.executable, str(script), "--pack", str(workspace / "scenario.json"),
            "--personas", str(workspace / "personas.json"), "--output", str(target)]
    for _ in range(2):
        result = subprocess.run(args, capture_output=True, text=True)
        assert result.returncode == 0, result.stdout + result.stderr
        assert json.loads(result.stdout)["prepared"] is True
    (target / "COMPLETE.json").unlink()
    result = subprocess.run(args, capture_output=True, text=True)
    assert result.returncode == 2
    assert json.loads(result.stdout)["prepared"] is False
    assert not (target / "COMPLETE.json").exists()


def test_managed_prepared_package_keeps_portraits_and_rights_evidence(workspace):
    target = workspace / "managed-out"
    build(workspace, target)
    names = {p.relative_to(target).as_posix() for p in target.rglob("*") if p.is_file()}
    assert {"personas/alice.jpg", "personas/bob.jpg", "personas/rights.txt"} <= names


def test_existing_pack_prepares_without_portraits_and_fingerprints_every_public_field(workspace):
    module = builder()
    existing = workspace / "existing-personas.json"
    first, second = workspace / "existing-first", workspace / "existing-second"
    module.build_scenario(workspace / "scenario.json", existing, first)
    module.build_scenario(workspace / "scenario.json", existing, second)
    assert bytes_in(first) == bytes_in(second)
    names = {p.relative_to(first).as_posix() for p in first.rglob("*") if p.is_file()}
    assert {n for n in names if n.startswith("personas/")} == {"personas/personas.json"}
    manifest = json.loads((first / "prepared-manifest.json").read_text())
    assert manifest["personaPackFingerprint"] == module.persona_fingerprint(existing)
    assert manifest["personaPackFingerprint"] != module.persona_fingerprint(workspace / "personas.json")
    prepared = json.loads((first / "personas" / "personas.json").read_text())
    assert prepared["version"] == "1.1" and prepared["accountSource"] == "Existing"
    from generator.validate_pack import validate_files
    assert validate_files(first / "scenario.json", first / "personas" / "personas.json") == []
    before = bytes_in(first)
    module.build_scenario(workspace / "scenario.json", existing, first)
    assert bytes_in(first) == before
    pack = json.loads(existing.read_text(encoding="utf-8"))
    pack["people"][0]["profile"]["jobTitle"] = "Changed target"
    save(workspace, "existing-personas.json", pack)
    assert module.persona_fingerprint(existing) != manifest["personaPackFingerprint"]
    with pytest.raises(ValueError):
        module.build_scenario(workspace / "scenario.json", existing, first)
    assert bytes_in(first) == before

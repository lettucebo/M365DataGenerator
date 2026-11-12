"""Prepare deterministic local scenario assets; never generate or execute a runner.

Workbook ZIP timestamp normalization adapts MS-4018 seed-data/generator/
build_scenario.py, Copyright (c) 2025 MoneyYu, MIT (see LICENSE).
"""

import argparse
import io
import json
import re
import shutil
import sys
from datetime import datetime
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

from openpyxl import Workbook
from openpyxl.worksheet.table import Table, TableStyleInfo

if not __package__:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from generator.validate_pack import (
    ContractError, MEDIA, ROOT, SCHEMA_VERSION, canonical_bytes, file_bytes, issue,
    load_json, reject_reparse, rows_for_sheet, safe_path, sha256, validate_files,
)

BUILDER_VERSION = "1.0.0"


def make_workbook(book):
    wb = Workbook()
    wb.properties.creator = "M365DataGenerator"
    wb.properties.created = wb.properties.modified = datetime(2020, 1, 1)
    for index, sheet in enumerate(book["sheets"]):
        ws = wb.active if index == 0 else wb.create_sheet()
        ws.title = sheet["name"]
        ws.append([c["name"] for c in sheet["columns"]])
        for row_number, row in enumerate(rows_for_sheet(sheet), 2):
            for col_number, (value, column) in enumerate(zip(row, sheet["columns"]), 1):
                cell = ws.cell(row_number, col_number)
                if column["type"] == "formula":
                    cell.value = column["formula"].replace("{row}", str(row_number))
                else:
                    cell.value = value
                    if isinstance(value, str):
                        cell.data_type = "s"
        # Header strings are data too: openpyxl otherwise guesses formulas.
        for cell in ws[1]:
            cell.data_type = "s"
        ws.freeze_panes = "A2"
        table = Table(displayName=sheet["table"], ref=f"A1:{ws.cell(ws.max_row, ws.max_column).coordinate}")
        table.tableStyleInfo = TableStyleInfo(name="TableStyleMedium2", showRowStripes=True)
        ws.add_table(table)
    stream = io.BytesIO()
    wb.save(stream)
    output = io.BytesIO()
    with ZipFile(io.BytesIO(stream.getvalue())) as archive, ZipFile(output, "w") as stable:
        for name in sorted(archive.namelist()):
            info = ZipInfo(name, (2020, 1, 1, 0, 0, 0))
            info.compress_type = ZIP_DEFLATED
            info.create_system = 0
            content = archive.read(name)
            if name == "docProps/core.xml":
                content, count = re.subn(rb"(<dcterms:modified[^>]*>)[^<]*", rb"\g<1>2020-01-01T00:00:00Z", content)
                if count != 1:
                    raise ValueError("Workbook modified timestamp was not found.")
            stable.writestr(info, content)
    return output.getvalue()


def persona_fingerprint(personas_path):
    """Canonical public document + portrait/evidence file hashes (no private IDs); Existing packs have no files."""
    personas_path = Path(personas_path)
    errors = validate_files(personas_path=personas_path)
    if errors:
        raise ContractError(errors)
    personas = load_json(personas_path)
    hashes = {}
    for avatar in personas.get("avatarAssets", []):
        for raw in (avatar["path"], avatar["rights"]["evidencePath"]):
            path = safe_path(personas_path.parent, raw)
            hashes[raw.replace("/", "\\")] = sha256(path.read_bytes())
    return sha256(canonical_bytes({"personas": personas, "files": hashes}))


def prepared_files(pack_path, personas_path):
    """Return all expected output bytes, after full offline validation."""
    pack_path, personas_path = Path(pack_path), Path(personas_path)
    errors = validate_files(pack_path, personas_path)
    if errors:
        raise ContractError(errors)
    pack, personas = load_json(pack_path), load_json(personas_path)
    files = {}

    def add(raw, data):
        folded = raw.casefold()
        if any(name.casefold() == folded for name in files):
            if files.get(raw) != data:
                raise ValueError("Prepared file paths collide.")
            return
        files[raw] = data

    prepared_pack = json.loads(canonical_bytes(pack))
    add("personas\\personas.json", canonical_bytes(personas))
    for avatar in personas.get("avatarAssets", []):
        for raw in (avatar["path"], avatar["rights"]["evidencePath"]):
            source = safe_path(personas_path.parent, raw)
            add("personas\\" + raw.replace("/", "\\"), source.read_bytes())
    books = {b["id"]: b for b in pack.get("workbooks", [])}
    generated = {}
    manifest_assets = []
    for index, asset in enumerate(pack["assets"]):
        if "workbookId" in asset:
            book_id = asset["workbookId"]
            if book_id not in generated:
                generated[book_id] = make_workbook(books[book_id])
            data = generated[book_id]
        else:
            data = file_bytes(safe_path(pack_path.parent, asset["localPath"]), asset["mediaType"])
            if sha256(data) != asset["sha256"]:
                raise ValueError("Source asset changed after validation.")
        suffix = ".jpeg" if asset["mediaType"] == "image/jpeg" and Path(asset["destination"]["name"]).suffix.casefold() == ".jpeg" else MEDIA[asset["mediaType"]][0]
        raw = f"assets\\{asset['id']}{suffix}"
        add(raw, data)
        if "localPath" in asset:
            prepared_pack["assets"][index]["localPath"] = raw
        manifest_assets.append({"id": asset["id"], "relativePath": raw, "sha256": sha256(data),
                                "mediaType": asset["mediaType"], "destination": asset["destination"]})
    add("scenario.json", canonical_bytes(prepared_pack))
    schema_fingerprint = sha256(canonical_bytes({
        path.name: sha256(path.read_bytes()) for path in sorted((ROOT / "schemas").glob("*.schema.json"))
    }))
    builder_fingerprint = sha256(canonical_bytes({
        name: sha256((ROOT / "generator" / name).read_bytes())
        for name in ("build_scenario.py", "validate_pack.py")
    }))
    manifest = {
        "schemaVersion": SCHEMA_VERSION, "builderVersion": BUILDER_VERSION,
        "builderFingerprint": builder_fingerprint, "schemaFingerprint": schema_fingerprint,
        "personaPackFingerprint": persona_fingerprint(personas_path),
        "sourceScenarioFingerprint": sha256(canonical_bytes(pack)),
        "scenarioId": pack["scenario"]["id"], "personaPackId": personas["packId"],
        "assets": manifest_assets,
        "files": {name: sha256(data) for name, data in sorted(files.items())},
    }
    manifest["fingerprint"] = sha256(canonical_bytes(manifest))
    add("prepared-manifest.json", canonical_bytes(manifest))
    add("COMPLETE.json", canonical_bytes({
        "schemaVersion": SCHEMA_VERSION, "fingerprint": manifest["fingerprint"],
        "manifestSha256": sha256(files["prepared-manifest.json"]),
    }))
    return files


def existing_files(root):
    files, directories = {}, set()

    def walk(folder):
        reject_reparse(folder)
        for path in folder.iterdir():
            reject_reparse(path)
            raw = str(path.relative_to(root))
            if path.is_dir():
                directories.add(raw)
                walk(path)
            elif path.is_file():
                files[raw] = path.read_bytes()
            else:
                raise ValueError("Prepared output contains a non-regular file.")

    walk(root)
    return files, directories


def build_scenario(pack_path, personas_path, output):
    """Create a NEW complete directory or verify exact bytes for read-only reuse."""
    output = Path(output).absolute()
    reject_reparse(output)
    files = prepared_files(pack_path, personas_path)
    expected_directories = {
        str(parent) for raw in files for parent in Path(raw).parents if str(parent) != "."
    }
    if output.exists():
        if not output.is_dir():
            raise ValueError("Output exists and is not a prepared directory.")
        actual_files, actual_directories = existing_files(output)
        if actual_files != files or actual_directories != expected_directories:
            raise ValueError("Existing output is incomplete, changed, or from different inputs/builder/schema. No files were overwritten.")
        return output
    if not output.parent.is_dir():
        raise ValueError("Output parent must already exist.")
    created = False
    try:
        output.mkdir()
        created = True
        for raw, data in files.items():
            path = safe_path(output, raw, must_exist=False)
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open("xb") as target:
                target.write(data)
        if existing_files(output) != (files, expected_directories):
            raise ValueError("Prepared output verification failed.")
    except BaseException:
        if created:
            shutil.rmtree(output)
        raise
    return output


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pack", type=Path, required=True)
    parser.add_argument("--personas", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        output = build_scenario(args.pack, args.personas, args.output)
        manifest = load_json(output / "prepared-manifest.json")
        print(json.dumps({"prepared": True, "output": str(output), "fingerprint": manifest["fingerprint"]}))
        return 0
    except ContractError as exc:
        errors = exc.errors
    except (OSError, ValueError) as exc:
        errors = [issue("$output", "prepare", str(exc), "Use a new local directory or restore the exact complete prepared bytes.")]
    print(json.dumps({"prepared": False, "errors": errors}, ensure_ascii=True))
    return 2


if __name__ == "__main__":
    raise SystemExit(main())

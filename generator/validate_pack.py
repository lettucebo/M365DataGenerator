"""Validate public JSON packs offline. No authentication or network operations."""

import argparse
import hashlib
import json
import math
import re
import stat
import warnings
from datetime import date, datetime, time
from html import unescape
from html.parser import HTMLParser
from pathlib import Path, PureWindowsPath
from urllib.parse import urlsplit
from xml.etree import ElementTree
from zipfile import BadZipFile, ZipFile
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from jsonschema import Draft202012Validator, FormatChecker
from openpyxl import load_workbook
from openpyxl.utils.exceptions import InvalidFileException
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SCHEMA_VERSION = "1.0"
MAX_JSON_BYTES = 16 * 1024 * 1024
MAX_IMAGE_PIXELS = 16_000_000
ASSET_TOKEN = re.compile(r"\{\{asset:([A-Za-z][A-Za-z0-9_-]{0,63})\}\}")
MEDIA = {
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": (".xlsx", "xl/workbook.xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"),
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document": (".docx", "word/document.xml", "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"),
    "application/vnd.openxmlformats-officedocument.presentationml.presentation": (".pptx", "ppt/presentation.xml", "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"),
    "application/pdf": (".pdf",),
    "text/plain": (".txt",),
    "image/jpeg": (".jpg", ".jpeg"),
}


class ContractError(ValueError):
    def __init__(self, errors):
        self.errors = errors
        super().__init__("Pack validation failed; inspect structured errors.")


class ContractArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        print(json.dumps({"valid": False, "errors": [
            issue("$arguments", "arguments", "Invalid command-line arguments.",
                  "Use --personas PATH, optionally --pack PATH; see --help.")
        ]}))
        raise SystemExit(2)


def issue(path, code, message, remediation="Correct the referenced field and validate again."):
    return {"path": path, "code": code, "message": message, "remediation": remediation}


def canonical_bytes(data):
    return (json.dumps(data, sort_keys=True, ensure_ascii=False, separators=(",", ":"), allow_nan=False) + "\n").encode("utf-8")


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def reject_reparse(path):
    path = Path(path).absolute()
    for part in reversed((path, *path.parents)):
        if part.exists() or part.is_symlink():
            info = part.lstat()
            if stat.S_ISLNK(info.st_mode) or getattr(info, "st_file_attributes", 0) & 0x400:
                raise ValueError("Reparse points and symbolic links are not permitted.")


def path_parts(raw):
    path = PureWindowsPath(raw)
    parts = raw.replace("/", "\\").split("\\")
    if path.is_absolute() or path.drive or path.root or any(
        not p or p in (".", "..") or p[-1:] in (" ", ".") or
        re.search(r'[<>:"|?*\x00-\x1f]', p) or
        re.fullmatch(r"(?i)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?", p)
        for p in parts
    ):
        raise ValueError("Use a safe relative path without traversal, devices, streams or absolute/UNC roots.")
    return parts


def safe_path(root, raw, must_exist=True):
    root = Path(root).absolute()
    path = root.joinpath(*path_parts(raw))
    reject_reparse(path)
    if must_exist and not path.is_file():
        raise ValueError("Referenced local file does not exist or is not a regular file.")
    return path


def load_json(path):
    path = Path(path)
    reject_reparse(path)
    if path.stat().st_size > MAX_JSON_BYTES:
        raise ValueError("JSON document exceeds the 16 MiB limit.")

    def unique_pairs(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("Duplicate JSON object key.")
            result[key] = value
        return result

    def invalid_constant(_):
        raise ValueError("Non-finite JSON numbers are not permitted.")

    def finite_float(value):
        result = float(value)
        if not math.isfinite(result):
            raise ValueError("Non-finite JSON numbers are not permitted.")
        return result

    return json.loads(path.read_text(encoding="utf-8-sig"), object_pairs_hook=unique_pairs,
                      parse_constant=invalid_constant, parse_float=finite_float)


def schema_errors(data, name, prefix="$"):
    schema = load_json(ROOT / "schemas" / f"{name}.schema.json")
    check = Draft202012Validator(schema, format_checker=FormatChecker())
    return [
        issue(prefix + "".join(f"/{str(p).replace('~', '~0').replace('/', '~1')}" for p in error.absolute_path),
              "schema", error.message)
        for error in sorted(check.iter_errors(data), key=lambda e: str(list(e.absolute_path)))
    ]


def jpeg_bytes(path):
    path = Path(path)
    if path.suffix.casefold() not in (".jpg", ".jpeg") or path.stat().st_size > 4 * 1024 * 1024:
        raise ValueError("Avatar must be a local JPEG no larger than 4 MiB.")
    with warnings.catch_warnings():
        warnings.simplefilter("error", Image.DecompressionBombWarning)
        with Image.open(path) as image:
            if image.format != "JPEG" or max(image.size) > 8192 or image.width * image.height > MAX_IMAGE_PIXELS:
                raise ValueError("JPEG decoding limits: maximum dimension 8192 and 16 million pixels.")
            image.verify()
        with Image.open(path) as image:
            image.load()
    return path.read_bytes()


def file_bytes(path, media_type):
    info = MEDIA[media_type]
    if path.stat().st_size > 32 * 1024 * 1024:
        raise ValueError("Asset exceeds the 32 MiB limit.")
    if media_type == "image/jpeg":
        return jpeg_bytes(path)
    if path.suffix.casefold() != info[0]:
        raise ValueError("Asset extension does not match the declared media type.")
    data = path.read_bytes()
    if len(info) == 3:
        with ZipFile(path) as archive:
            entries = archive.infolist()
            names = [e.filename for e in entries]
            if len(names) != len(set(names)) or len(entries) > 10000 or sum(e.file_size for e in entries) > 64 * 1024 * 1024:
                raise ValueError("Office archive exceeds decoding limits or contains duplicate entries.")
            if any(e.flag_bits & 1 or e.filename.startswith(("/", "\\")) or ".." in e.filename.replace("\\", "/").split("/") for e in entries):
                raise ValueError("Unsafe or encrypted Office archive.")
            content_types = ElementTree.fromstring(archive.read("[Content_Types].xml"))
            if info[1] not in names or not any(
                node.get("PartName") == "/" + info[1] and node.get("ContentType") == info[2]
                for node in content_types
            ):
                raise ValueError("Office main part does not match the declared file type.")
            if any("macroEnabled" in n.get("ContentType", "") or "vbaProject" in n.get("ContentType", "") for n in content_types):
                raise ValueError("Macro-enabled files are not supported.")
            main = ElementTree.fromstring(archive.read(info[1]))
            expected_tag = {
                ".xlsx": "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}workbook",
                ".docx": "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}document",
                ".pptx": "{http://schemas.openxmlformats.org/presentationml/2006/main}presentation",
            }[info[0]]
            if main.tag != expected_tag:
                raise ValueError("Office main part has an invalid document root.")
            if archive.testzip():
                raise ValueError("Office archive is corrupt.")
        if info[0] == ".xlsx":
            workbook = load_workbook(path, read_only=True, data_only=False, keep_links=False)
            try:
                if not workbook.sheetnames:
                    raise ValueError("Workbook must contain at least one worksheet.")
            finally:
                workbook.close()
    elif media_type == "application/pdf":
        if not data.startswith(b"%PDF-") or not data.rstrip().endswith(b"%%EOF"):
            raise ValueError("Invalid PDF signature.")
    elif media_type == "text/plain":
        if b"\x00" in data:
            raise ValueError("Text asset contains NUL bytes.")
        data.decode("utf-8")
    return data


def unique(values, path, errors, label="IDs"):
    folded = [str(v).casefold() for v in values]
    if len(folded) != len(set(folded)):
        errors.append(issue(path, "duplicate", f"{label} must be unique (case-insensitive)."))


def validate_existing_personas(pack):
    """Existing-account packs are logical targets only: no files, portraits, licenses or identifiers."""
    errors = []
    people = pack["people"]
    unique([p["personaId"] for p in people], "$personas/people", errors, "Persona IDs")
    unique([b["id"] for b in pack["businessUnits"]], "$personas/businessUnits", errors)
    unique([p["identityHint"]["alias"] for p in people if "alias" in p.get("identityHint", {})], "$personas/people", errors, "Aliases")
    by_id = {p["personaId"]: p for p in people}
    for index, person in enumerate(people):
        where = f"$personas/people/{index}"
        if person.get("profile", {}).get("companyName", pack["company"]["name"]) != pack["company"]["name"]:
            errors.append(issue(where + "/profile/companyName", "company", "Profile companyName must match the public company name."))
        reference = person.get("managerRef")
        if reference is None:
            continue
        seen, current = {person["personaId"]}, reference
        while current is not None:
            if current not in by_id:
                errors.append(issue(where + "/managerRef", "reference", "Manager is undeclared."))
                break
            if current in seen:
                errors.append(issue(where + "/managerRef", "cycle", "Manager must be another persona and the graph cannot contain a cycle."))
                break
            seen.add(current)
            current = by_id[current].get("managerRef")
    return errors


def validate_personas(pack, root):
    errors = schema_errors(pack, "personas", "$personas")
    if errors:
        return errors
    if pack["version"] == "1.1":
        return validate_existing_personas(pack)
    people, avatars = pack["people"], pack["avatarAssets"]
    for label, rows, key in (("people", people, "personaId"), ("avatarAssets", avatars, "id"), ("businessUnits", pack["businessUnits"], "id")):
        unique([r[key] for r in rows], f"$personas/{label}", errors)
    unique([p["alias"] for p in people], "$personas/people", errors, "Aliases")
    unique([p["avatarAssetId"] for p in people], "$personas/people", errors, "Portrait references")
    unique([a["sha256"] for a in avatars], "$personas/avatarAssets", errors, "Portrait content hashes")
    unique([a["path"].replace("/", "\\") for a in avatars], "$personas/avatarAssets", errors, "Portrait paths")
    by_id = {p["personaId"]: p for p in people}
    avatar_ids = {a["id"] for a in avatars}
    for index, person in enumerate(people):
        where = f"$personas/people/{index}"
        if person["avatarAssetId"] not in avatar_ids:
            errors.append(issue(where + "/avatarAssetId", "reference", "Avatar is undeclared."))
        if person["companyName"] != pack["company"]["name"]:
            errors.append(issue(where + "/companyName", "company", "Profile companyName must match the public company name."))
        seen, current = set(), person["personaId"]
        while current is not None:
            if current not in by_id:
                errors.append(issue(where + "/managerRef", "reference", "Manager is undeclared."))
                break
            if current in seen:
                errors.append(issue(where + "/managerRef", "cycle", "Manager graph contains a cycle."))
                break
            seen.add(current)
            current = by_id[current]["managerRef"]
    if {p["avatarAssetId"] for p in people} != avatar_ids:
        errors.append(issue("$personas/avatarAssets", "reference", "Every portrait must be assigned to exactly one persona."))
    decoded_portraits = []
    for index, avatar in enumerate(avatars):
        where = f"$personas/avatarAssets/{index}"
        try:
            path = safe_path(root, avatar["path"])
            data = jpeg_bytes(path)
            if sha256(data) != avatar["sha256"]:
                raise ValueError("JPEG SHA-256 does not match.")
            with Image.open(path) as image:
                decoded_portraits.append(sha256(canonical_bytes(image.size) + image.convert("RGB").tobytes()))
            evidence = safe_path(root, avatar["rights"]["evidencePath"])
            if not 0 < evidence.stat().st_size <= 65536 or not evidence.read_text(encoding="utf-8").strip():
                raise ValueError("Rights evidence must be nonempty UTF-8 text no larger than 64 KiB.")
        except (OSError, ValueError, Image.DecompressionBombError, Image.DecompressionBombWarning) as exc:
            errors.append(issue(where, "avatar", str(exc), "Supply a unique safe local JPEG, matching SHA-256 and local rights evidence."))
    unique(decoded_portraits, "$personas/avatarAssets", errors, "Decoded portraits")
    return errors


class SafeHTML(HTMLParser):
    TAGS = {"p", "br", "strong", "em", "b", "i", "u", "table", "thead", "tbody", "tr", "th", "td", "a", "ul", "ol", "li"}

    def __init__(self, teams=False):
        super().__init__(convert_charrefs=False)
        self.teams = teams
        self.stack = []
        self.mentions = []
        self.active_mention = None

    def handle_starttag(self, tag, attrs):
        if tag not in self.TAGS and not (tag == "at" and self.teams):
            raise ValueError("HTML tag is not in the safe allowlist.")
        if len(attrs) != len(dict(attrs)):
            raise ValueError("Duplicate HTML attributes are not permitted.")
        allowed = {"href"} if tag == "a" else {"id"} if tag == "at" else set()
        if any(key not in allowed for key, _ in attrs):
            raise ValueError("HTML attribute is not in the safe allowlist.")
        attributes = dict(attrs)
        if tag == "a":
            href = attributes.get("href", "")
            if not ASSET_TOKEN.fullmatch(href):
                parts = urlsplit(href)
                if (parts.scheme not in ("https", "http", "mailto") or
                    any(ord(c) < 33 or ord(c) == 127 for c in href) or "\\" in href or
                    (parts.scheme in ("https", "http") and (not parts.hostname or parts.username or parts.password)) or
                    (parts.scheme == "mailto" and not re.fullmatch(r"[^@\s?]+@[^@\s?]+", parts.path))):
                    raise ValueError("Link must be an asset token or safe absolute HTTP(S)/mailto URL.")
        if self.active_mention is not None:
            raise ValueError("Teams mention text cannot contain nested tags.")
        if tag == "at":
            if not re.fullmatch(r"0|[1-9][0-9]*", attributes.get("id", "")):
                raise ValueError("Teams <at> requires a nonnegative integer id.")
            self.active_mention = [int(attributes["id"]), ""]
        if tag != "br":
            self.stack.append(tag)

    def handle_startendtag(self, tag, attrs):
        if tag != "br":
            raise ValueError("Only br may be self-closing.")
        self.handle_starttag(tag, attrs)

    def handle_endtag(self, tag):
        if not self.stack or self.stack.pop() != tag:
            raise ValueError("HTML tags must be balanced and correctly nested.")
        if tag == "at":
            self.mentions.append(tuple(self.active_mention))
            self.active_mention = None

    def handle_data(self, data):
        if "<" in data:
            raise ValueError("Malformed HTML markup; encode literal less-than signs as &lt;.")
        if self.active_mention is not None:
            self.active_mention[1] += data

    def handle_entityref(self, name):
        if self.active_mention is not None:
            self.active_mention[1] += unescape(f"&{name};")

    def handle_charref(self, name):
        if self.active_mention is not None:
            self.active_mention[1] += unescape(f"&#{name};")

    def handle_comment(self, data):
        raise ValueError("HTML comments are not supported.")

    def handle_decl(self, decl):
        raise ValueError("HTML declarations are not supported.")

    def handle_pi(self, data):
        raise ValueError("HTML processing instructions are not supported.")

    def unknown_decl(self, data):
        raise ValueError("Unknown HTML declarations are not supported.")

    def finish(self, body):
        self.feed(body)
        if self.rawdata:
            raise ValueError("Incomplete HTML markup or character reference.")
        self.close()
        if self.stack:
            raise ValueError("HTML tags must be closed.")
        return self.mentions


def rows_for_sheet(sheet):
    if "rows" in sheet:
        return sheet["rows"]
    import random
    rule = sheet["generate"]
    if rule["min"] > rule["max"]:
        raise ValueError("Recipe min must not exceed max.")
    rng = random.Random(rule["seed"])
    rows = [[dimension, period, rng.randint(rule["min"], rule["max"])]
            for dimension in rule["dimensions"] for period in rule["periods"]]
    keys = set()
    for override in rule["overrides"]:
        key = (override["dimension"], override["period"])
        if key in keys:
            raise ValueError("Duplicate recipe override.")
        keys.add(key)
        matches = [r for r in rows if r[:2] == list(key)]
        if len(matches) != 1:
            raise ValueError("Recipe override must match exactly one generated row.")
        matches[0][2] = override["value"]
    return rows


def typed_value(value, kind):
    if kind in ("text", "string", "choice", "dateTime"):
        return isinstance(value, str)
    if kind == "boolean":
        return isinstance(value, bool)
    if kind == "integer":
        return isinstance(value, int) and not isinstance(value, bool) and abs(value) <= 9007199254740991
    if kind == "number":
        return (isinstance(value, (int, float)) and not isinstance(value, bool) and
                -1e308 <= value <= 1e308 and
                (not isinstance(value, int) or abs(value) <= 9007199254740991))
    return kind == "formula" and value is None


def validate_workbooks(pack, errors):
    books = pack.get("workbooks", [])
    unique([b["id"] for b in books], "$scenario/workbooks", errors)
    for bi, book in enumerate(books):
        where = f"$scenario/workbooks/{bi}"
        unique([s["name"] for s in book["sheets"]], where, errors, "Worksheet names")
        unique([s["table"] for s in book["sheets"]], where, errors, "Table names")
        for si, sheet in enumerate(book["sheets"]):
            point = f"{where}/sheets/{si}"
            unique([c["name"] for c in sheet["columns"]], point, errors, "Column names")
            try:
                if re.search(r"[\[\]\\/*?:\x00-\x1f]", sheet["name"]) or sheet["name"].startswith("'") or sheet["name"].endswith("'"):
                    raise ValueError("Invalid Excel sheet name.")
                if re.fullmatch(r"(?i)([A-Z]{1,3}[1-9][0-9]*|R[0-9]+C[0-9]+|R|C)", sheet["table"]):
                    raise ValueError("Excel table name must not be a cell reference.")
                if "generate" in sheet and [c["type"] for c in sheet["columns"]] not in (["string", "string", "integer"], ["string", "string", "number"]):
                    raise ValueError("Generated recipe requires string/string/number columns.")
                for column in sheet["columns"]:
                    if re.search(r"[\x00-\x08\x0b\x0c\x0e-\x1f]", column["name"]):
                        raise ValueError("Excel column name contains illegal XML characters.")
                    if column["type"] == "formula":
                        formula = column["formula"]
                        if len(formula) > 2048 or re.search(r"[\x00-\x1f]", formula) or any(c in formula for c in ("[", "]", "!", "|")) or re.search(r"(?i)(https?:|WEBSERVICE|HYPERLINK|RTD|DDE|CALL|REGISTER)", formula):
                            raise ValueError("Formula must be a local worksheet expression, without external references.")
                        formula.replace("{row}", "2")
                        if re.search(r"[{}]", formula.replace("{row}", "2")):
                            raise ValueError("Only {row} is supported in formula templates.")
                for row in rows_for_sheet(sheet):
                    if len(row) != len(sheet["columns"]) or any(not typed_value(v, c["type"]) for v, c in zip(row, sheet["columns"])):
                        raise ValueError("Row width or value type does not match the declared columns.")
                    if any(isinstance(v, str) and (len(v) > 32767 or re.search(r"[\x00-\x08\x0b\x0c\x0e-\x1f]", v)) for v in row):
                        raise ValueError("Excel string contains illegal XML characters or exceeds the cell limit.")
            except ValueError as exc:
                errors.append(issue(point, "recipe", str(exc)))


def validate_scenario(pack, personas, root):
    errors = schema_errors(pack, "scenario", "$scenario")
    if errors:
        return errors
    roles = pack["roles"]
    persona_ids = {p["personaId"] for p in personas["people"]}
    units = {u["id"] for u in personas["businessUnits"]}
    if pack["scenario"]["personaPackId"] != personas["packId"]:
        errors.append(issue("$scenario/scenario/personaPackId", "reference", "Scenario references a different Persona Pack."))
    unique([r["personaId"] for r in roles.values()], "$scenario/roles", errors, "Role personas")
    for key, role in roles.items():
        if key.casefold() == "presenter" or role["personaId"] not in persona_ids or role["businessUnitId"] not in units:
            errors.append(issue(f"$scenario/roles/{key}", "role", "Role must reference an existing persona/business unit; Presenter is reserved."))
    try:
        zone = ZoneInfo(pack["scenario"]["timeZone"])
        anchor = date.fromisoformat(pack["scenario"]["anchorDate"])
        cutoff = datetime.combine(anchor, time.max, zone)
    except (ValueError, ZoneInfoNotFoundError):
        errors.append(issue("$scenario/scenario", "time", "Use a real anchorDate and IANA timeZone."))
        cutoff = None
    unique([s["id"] for s in pack["stories"]], "$scenario/stories", errors)
    unique([f["id"] for s in pack["stories"] for f in s["facts"]], "$scenario/stories", errors, "Fact IDs")
    stories = {s["id"] for s in pack["stories"]}
    assets = {a["id"]: a for a in pack["assets"]}
    unique([a["id"] for a in pack["assets"]], "$scenario/assets", errors)
    destinations = []
    books = {b["id"] for b in pack.get("workbooks", [])}
    used_books = set()
    drives = {d["id"]: d for d in pack.get("onedrive", {}).get("drives", [])}
    sites = {s["id"]: s for s in pack.get("sharepoint", {}).get("sites", [])}
    for index, asset in enumerate(pack["assets"]):
        where = f"$scenario/assets/{index}"
        dest = asset["destination"]
        try:
            parts = path_parts(dest["folder"])
            if len(path_parts(dest["name"])) != 1:
                raise ValueError("Destination name must be a basename.")
            extension = Path(dest["name"]).suffix.casefold()
            allowed = (".jpg", ".jpeg") if asset["mediaType"] == "image/jpeg" else (MEDIA[asset["mediaType"]][0],)
            if extension not in allowed:
                raise ValueError("Destination extension must match the media type.")
            destinations.append("\\".join([dest["workload"], dest["containerId"], *parts, dest["name"]]))
            containers = drives if dest["workload"] == "onedrive" else sites
            if dest["containerId"] not in containers or asset["id"] not in containers[dest["containerId"]]["assetRefs"]:
                raise ValueError("Asset destination must reference a declared upload container listing this asset.")
            if "workbookId" in asset:
                if asset["workbookId"] not in books:
                    raise ValueError("Asset workbook recipe is undeclared.")
                used_books.add(asset["workbookId"])
            else:
                data = file_bytes(safe_path(root, asset["localPath"]), asset["mediaType"])
                if sha256(data) != asset["sha256"]:
                    raise ValueError("Asset SHA-256 does not match.")
        except (OSError, ValueError, TypeError, IndexError, KeyError, BadZipFile, InvalidFileException, ElementTree.ParseError, Image.DecompressionBombError, Image.DecompressionBombWarning) as exc:
            errors.append(issue(where, "asset", str(exc)))
    unique(destinations, "$scenario/assets", errors, "Upload destinations")
    destination_set = {p.casefold() for p in destinations}
    for destination in destination_set:
        parts = destination.split("\\")
        if any("\\".join(parts[:i]) in destination_set for i in range(1, len(parts))):
            errors.append(issue("$scenario/assets", "destination", "An upload file path cannot also be another asset's parent folder."))
    if books != used_books:
        errors.append(issue("$scenario/workbooks", "recipe", "Every selected workbook must be referenced by an uploaded asset."))
    validate_workbooks(pack, errors)

    def check_roles(names, where, presenter=True):
        for name in names:
            if name not in roles and not (presenter and name == "Presenter"):
                errors.append(issue(where, "role", "Undeclared or reserved author role."))

    def check_refs(refs, where):
        if any(a not in assets for a in refs):
            errors.append(issue(where, "reference", "Asset reference is undeclared."))

    def check_body(item, where, teams=False):
        check_refs(item["assetRefs"], where)
        body = item["bodyHtml"]
        tokens = ASSET_TOKEN.findall(body)
        if "{{asset:" in ASSET_TOKEN.sub("", body) or any(t not in assets or t not in item["assetRefs"] for t in tokens):
            errors.append(issue(where + "/bodyHtml", "asset-token", "Asset tokens must be valid, declared and included in assetRefs."))
        try:
            parsed = SafeHTML(teams).finish(body)
            if teams:
                mentions = item["mentions"]
                expected = [(m["id"], m["text"]) for m in mentions]
                if parsed != expected or [m["id"] for m in mentions] != list(range(len(mentions))):
                    raise ValueError("Teams <at> elements must match mentions in order with contiguous IDs starting at zero.")
                check_roles([m["role"] for m in mentions], where)
                for mention in mentions:
                    if mention["text"] != mention["role"]:
                        raise ValueError("Mention text must equal its public role label; identity is resolved only from the private binding.")
        except ValueError as exc:
            errors.append(issue(where + "/bodyHtml", "html", str(exc)))

    mail_ids = []
    threads = pack.get("outlook", {}).get("threads", [])
    unique([t["id"] for t in threads], "$scenario/outlook/threads", errors)
    for ti, thread in enumerate(threads):
        where = f"$scenario/outlook/threads/{ti}"
        if thread["storyId"] not in stories:
            errors.append(issue(where, "reference", "Mail storyId is undeclared."))
        previous = {}
        for mi, message in enumerate(thread["messages"]):
            point = f"{where}/messages/{mi}"
            mail_ids.append(message["id"])
            check_roles([message["fromRole"]], point, False)
            recipients = message["toRoles"] + message["ccRoles"]
            check_roles(recipients, point)
            unique(recipients, point, errors, "Recipients")
            if "Presenter" not in recipients:
                errors.append(issue(point, "presenter", "Presenter must be in To or CC of every mail."))
            if mi == 0:
                if message["action"] != "send" or message["parentId"] is not None:
                    errors.append(issue(point, "mail-order", "Thread must start with send and null parentId."))
            else:
                parent = previous.get(message["parentId"])
                if message["action"] != "reply" or not parent or message["fromRole"] not in parent["toRoles"] + parent["ccRoles"]:
                    errors.append(issue(point, "mail-parent", "Reply must reference an earlier message in this thread whose recipients include the author."))
            check_body(message, point)
            previous[message["id"]] = message
    unique(mail_ids, "$scenario/outlook", errors, "Mail message IDs across threads")

    teams_ids = []
    channels = pack.get("teams", {}).get("channels", [])
    unique([c["id"] for c in channels], "$scenario/teams/channels", errors)
    unique([c["displayName"] for c in channels], "$scenario/teams/channels", errors, "Channel names")
    for ci, channel in enumerate(channels):
        where = f"$scenario/teams/channels/{ci}"
        check_roles(channel["memberRoles"], where)
        if re.search(r'[+#%&\\/:<>?|"*]', channel["displayName"]) or len(channel["displayName"]) > 50:
            errors.append(issue(where, "channel", "Invalid Teams channel displayName."))
        previous_post_time = None
        for mi, post in enumerate(channel["messages"]):
            post_time = None
            previous_reply_time = None
            for ri, item in enumerate([post, *post["replies"]]):
                point = f"{where}/messages/{mi}" + (f"/replies/{ri - 1}" if ri else "")
                teams_ids.append(item["id"])
                check_roles([item["fromRole"]], point, False)
                if item["fromRole"] not in channel["memberRoles"] or any(m["role"] not in channel["memberRoles"] for m in item["mentions"]):
                    errors.append(issue(point, "membership", "Actual author and mentioned roles must be channel members."))
                if item["storyId"] not in stories or (ri and item["storyId"] != post["storyId"]):
                    errors.append(issue(point, "reference", "Story must exist and replies must use their parent's storyId."))
                try:
                    timestamp = datetime.fromisoformat(item["createdDateTime"].replace("Z", "+00:00"))
                    if timestamp.tzinfo is None or (cutoff and timestamp > cutoff):
                        raise ValueError("Timestamp must include an offset and must not be after anchorDate in scenario timeZone.")
                    if ri:
                        if timestamp <= (previous_reply_time or post_time):
                            raise ValueError("Replies must be strictly after their parent and preceding reply.")
                        previous_reply_time = timestamp
                    else:
                        if previous_post_time and timestamp <= previous_post_time:
                            raise ValueError("Channel root messages must be in strictly increasing time order.")
                        post_time = previous_post_time = timestamp
                except (ValueError, TypeError) as exc:
                    errors.append(issue(point, "time", str(exc)))
                check_body(item, point, True)
    unique(teams_ids, "$scenario/teams", errors, "Teams message IDs across all parents/channels")

    unique([d["id"] for d in pack.get("onedrive", {}).get("drives", [])], "$scenario/onedrive", errors)
    unique([d["ownerRole"] for d in drives.values()], "$scenario/onedrive", errors, "OneDrive owners")
    for drive in drives.values():
        check_roles([drive["ownerRole"]], "$scenario/onedrive")
        check_refs(drive["assetRefs"], "$scenario/onedrive")
        for ref in drive["assetRefs"]:
            if ref in assets and (assets[ref]["destination"]["workload"], assets[ref]["destination"]["containerId"]) != ("onedrive", drive["id"]):
                errors.append(issue("$scenario/onedrive", "destination", "Each asset must be uploaded to exactly its declared destination."))
    site_rows = pack.get("sharepoint", {}).get("sites", [])
    unique([s["id"] for s in site_rows], "$scenario/sharepoint", errors)
    unique([s["alias"] for s in site_rows], "$scenario/sharepoint", errors, "Site aliases")
    for si, site in enumerate(site_rows):
        where = f"$scenario/sharepoint/sites/{si}"
        check_roles(site["ownerRoles"] + site["memberRoles"], where)
        check_refs(site["assetRefs"], where)
        if "Presenter" not in site["ownerRoles"]:
            errors.append(issue(where, "presenter", "Presenter must own each SharePoint site."))
        for ref in site["assetRefs"]:
            if ref in assets and (assets[ref]["destination"]["workload"], assets[ref]["destination"]["containerId"]) != ("sharepoint", site["id"]):
                errors.append(issue(where, "destination", "Site asset reference differs from its declared upload destination."))
        unique([l["id"] for l in site["lists"]], where, errors, "List IDs")
        unique([l["displayName"] for l in site["lists"]], where, errors, "List names")
        for li, listing in enumerate(site["lists"]):
            point = f"{where}/lists/{li}"
            unique([c["id"] for c in listing["columns"]], point, errors, "Column IDs")
            unique([c["name"] for c in listing["columns"]], point, errors, "Column names")
            unique([i["id"] for i in listing["items"]], point, errors, "Item IDs")
            columns = {c["id"]: c for c in listing["columns"]}
            for ii, item in enumerate(listing["items"]):
                values = item["values"]
                if set(values) != set(columns):
                    errors.append(issue(f"{point}/items/{ii}", "list-values", "Item values must contain exactly the declared column IDs."))
                    continue
                for key, value in values.items():
                    column = columns[key]
                    valid = typed_value(value, column["type"])
                    if valid and column["type"] == "choice":
                        valid = value in column["choices"]
                    if valid and column["type"] == "dateTime":
                        try:
                            valid = FormatChecker().conforms(value, "date-time") and datetime.fromisoformat(value.replace("Z", "+00:00")).tzinfo is not None
                        except ValueError:
                            valid = False
                    if not valid:
                        errors.append(issue(f"{point}/items/{ii}/values/{key}", "list-type", "List item does not match the declared column type/choices."))
    return errors


def validate_files(pack_path=None, personas_path=None):
    """Return [{path, code, message, remediation}], never credentials or file contents."""
    if personas_path is None:
        return [issue("$personas", "input", "--personas is required.")]
    try:
        personas = load_json(personas_path)
        errors = validate_personas(personas, Path(personas_path).parent)
        if errors or pack_path is None:
            return errors
        pack = load_json(pack_path)
        return validate_scenario(pack, personas, Path(pack_path).parent)
    except (OSError, ValueError, RecursionError) as exc:
        return [issue("$", "input", f"Cannot read a safe JSON input: {type(exc).__name__}.",
                      "Supply readable local UTF-8 JSON with unique keys, finite values and no reparse points.")]


def main(argv=None):
    parser = ContractArgumentParser(description=__doc__)
    parser.add_argument("--pack", type=Path)
    parser.add_argument("--personas", type=Path, required=True)
    args = parser.parse_args(argv)
    errors = validate_files(args.pack, args.personas)
    print(json.dumps({"valid": not errors, "errors": errors}, ensure_ascii=True))
    return 2 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())

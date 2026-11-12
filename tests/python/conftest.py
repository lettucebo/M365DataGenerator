import json
import shutil
import time
import uuid
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]


@pytest.fixture
def workspace():
    root = ROOT / "tests" / ".scratch" / uuid.uuid4().hex
    root.mkdir(parents=True)
    for path in (ROOT / "tests" / "fixtures").iterdir():
        if path.is_file():
            shutil.copyfile(path, root / path.name)
    yield root
    for attempt in range(10):
        try:
            shutil.rmtree(root)
            break
        except PermissionError as exc:
            if getattr(exc, "winerror", None) != 32 or attempt == 9:
                raise
            time.sleep(0.05 * (attempt + 1))


@pytest.fixture
def documents(workspace):
    return (
        json.loads((workspace / "personas.json").read_text(encoding="utf-8")),
        json.loads((workspace / "scenario.json").read_text(encoding="utf-8")),
    )


def save(root, name, data):
    (root / name).write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")

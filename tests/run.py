"""Run Lua 5.1 tests without a KOReader installation.

    uv run --with lupa python tests/run.py

The plugin's Lua modules run unchanged against substituted KOReader services,
a real JSON codec, and both simulated sockets and a real TCP adapter.
No real model API is contacted.
"""
import hashlib
import json
from pathlib import Path
import tempfile
import os

from lupa.lua51 import LuaRuntime, lua_type

from http_smoke import run as http_smoke


ROOT = Path(__file__).resolve().parent.parent
os.chdir(ROOT)
lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute("io.stdout:setvbuf('no')")


def from_lua(value):
    if lua_type(value) != "table":
        return value
    keys = list(value.keys())
    if keys and set(keys) == set(range(1, len(keys) + 1)):
        return [from_lua(value[i]) for i in range(1, len(keys) + 1)]
    return {key: from_lua(value[key]) for key in keys}


with tempfile.TemporaryDirectory(prefix="kentread-tests-") as directory:
    root = Path(directory)
    (root / "settings").mkdir()
    (root / "plugin").mkdir()
    (root / "plugin" / "config.sample.lua").write_bytes(
        (ROOT / "config.sample.lua").read_bytes()
    )
    (root / "plugin" / "setup.html").write_bytes((ROOT / "setup.html").read_bytes())
    globals_ = lua.globals()
    globals_.test_dir = directory
    globals_.sha256_hex = lambda text: hashlib.sha256(text.encode("utf-8")).hexdigest()
    globals_.json_encode = lambda value: json.dumps(
        from_lua(value), ensure_ascii=False, separators=(",", ":")
    )
    globals_.json_decode = lambda value: lua.table_from(json.loads(value), recursive=True)
    globals_.mkdir_p = lambda path: Path(path).mkdir(parents=True, exist_ok=True)
    for path in sorted(ROOT.glob("*.lua")):
        lua.execute("assert(loadfile(...))", str(path))
    lua.execute((ROOT / "tests" / "test.lua").read_text())
    http_smoke(lua, str(root / "plugin"))
    settings = root / "settings" / "kentread.json"
    assert settings.stat().st_mode & 0o777 == 0o600
    print("PASS: settings permissions are owner-only (0600)")

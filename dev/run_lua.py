"""
Run a Lua file inside X4's own LuaJIT (lua51_64.dll in the game folder), with string globals preset.

    python run_lua.py <script.lua> [NAME=value ...]

Used by run_tests.py to fly ui/x4_coop.lua through sim.lua without starting the game.
"""
import ctypes
import sys
from pathlib import Path

GAME_DIR = Path(__file__).resolve().parents[3]
LUA_GLOBALSINDEX = -10002
_lua = None


def _load():
    global _lua
    if _lua is None:
        lua = ctypes.CDLL(str(GAME_DIR / "lua51_64.dll"))
        lua.luaL_newstate.restype = ctypes.c_void_p
        lua.luaL_openlibs.argtypes = [ctypes.c_void_p]
        lua.luaL_loadbuffer.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p]
        lua.lua_pcall.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int]
        lua.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
        lua.lua_tolstring.restype = ctypes.c_char_p
        lua.lua_pushstring.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        lua.lua_setfield.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p]
        lua.lua_close.argtypes = [ctypes.c_void_p]
        _lua = lua
    return _lua


def run(script, globals_=None):
    """Run script in a fresh Lua state. Returns (ok, error message or '')."""
    lua = _load()
    state = lua.luaL_newstate()
    try:
        lua.luaL_openlibs(state)
        for name, value in (globals_ or {}).items():
            lua.lua_pushstring(state, str(value).encode())
            lua.lua_setfield(state, LUA_GLOBALSINDEX, name.encode())
        code = Path(script).read_bytes()
        if lua.luaL_loadbuffer(state, code, len(code), ("@" + str(script)).encode()) != 0:
            return False, "load error: " + lua.lua_tolstring(state, -1, None).decode()
        if lua.lua_pcall(state, 0, 0, 0) != 0:
            return False, "runtime error: " + lua.lua_tolstring(state, -1, None).decode()
        return True, ""
    finally:
        lua.lua_close(state)


if __name__ == "__main__":
    ok, err = run(sys.argv[1], dict(a.split("=", 1) for a in sys.argv[2:]))
    if not ok:
        print(err)
    sys.exit(0 if ok else 1)

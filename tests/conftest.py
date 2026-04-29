# Test helpers — make `bin/consolerdp-daemon` importable as a module.
import importlib.machinery
import importlib.util
import pathlib
import sys

_BIN = pathlib.Path(__file__).resolve().parent.parent / "bin" / "consolerdp-daemon"


def load_daemon():
    loader = importlib.machinery.SourceFileLoader("consolerdp_daemon", str(_BIN))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["consolerdp_daemon"] = mod
    loader.exec_module(mod)
    return mod

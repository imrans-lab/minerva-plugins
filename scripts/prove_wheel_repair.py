#!/usr/bin/env python3
"""Prove a repaired wheel carries the C++ runtime it was missing.

delvewheel writes an output wheel whether or not it vendored anything, so the
repair has to be proven by CONTENT, and a filename is not enough content. Two
conditions, both required:

  VENDORED   some member of the wheel matches the pattern the lock states
             (delvewheel copies the DLL in under a name-mangled path).
  REBOUND    no PE in the wheel — the extension AND every runtime DLL
             vendored beside it — still imports one of the forbidden DLLs by
             its BARE name, in EITHER import directory (the normal one or the
             delay-load one). delvewheel mangles the name of
             every DLL it vendors and patches the import table to match, so a
             bare `MSVCP140.dll` in an import table means that extension is
             still resolving the runtime from the machine — which succeeds on
             every CI runner, where the redistributable is installed, and
             fails for the user the bundle exists to serve.

The second condition is what a filename check cannot see: a wheel can carry a
vendored copy AND an extension still bound to the system one.

Usage:
    prove_wheel_repair.py <wheel> <member-regex> [--tooling DIR]
                          [--forbid NAME]...

`--tooling` is the directory the repair tool was installed into; pefile is a
delvewheel dependency and lives there. It is only imported when the wheel
actually contains a PE to read, so the member check stands on its own.
"""

from __future__ import annotations

import argparse
import re
import sys
import zipfile

#: Members whose import tables are read. Anything else in a wheel is data.
PE_SUFFIXES = (".pyd", ".dll")


def pe_members(names) -> list:
    """Every PE in the wheel, the vendored runtime copies INCLUDED.

    A vendored DLL is a dependency of the extension and has dependencies of
    its own: delvewheel mangles and rebinds a whole tree, and a copy it
    missed — a mangled msvcp140_1 still importing the machine's bare
    MSVCP140.dll — leaves the wheel machine-dependent while every name in it
    looks repaired. Skipping the vendored files because their NAMES match the
    proof pattern is exactly the hole that hides.
    """
    return [name for name in names if name.lower().endswith(PE_SUFFIXES)]


def vendored(names, pattern: str) -> bool:
    """Did the repair copy something matching `pattern` into the wheel?"""
    return any(re.search(pattern, name, re.I) for name in names)


def offending(imports, forbidden) -> list:
    """The forbidden DLLs this import list still names, in order.

    An exact, case-insensitive name match: `msvcp140-1a2b3c.dll` is the
    vendored copy and is fine, `msvcp140.dll` is the machine's and is not.
    """
    wanted = {name.lower() for name in forbidden}
    return [name for name in imports if name.lower() in wanted]


#: The import directories a PE can name a DLL in. The delay-load one is a
#: second, equally real dependency: the loader resolves it on the first call
#: instead of at load time, so a .pyd that delay-loads MSVCP140.dll imports it
#: from the machine just as surely as one that lists it normally — it simply
#: fails later, on the first call into the runtime.
IMPORT_DIRECTORIES = (
    "DIRECTORY_ENTRY_IMPORT",
    "DIRECTORY_ENTRY_DELAY_IMPORT",
)


def names_from(image) -> list:
    """The DLL names a parsed PE image depends on, over every directory."""
    names = []
    for attribute in IMPORT_DIRECTORIES:
        for entry in getattr(image, attribute, None) or []:
            dll = getattr(entry, "dll", None)
            if not dll:
                continue
            names.append(dll.decode("ascii", "replace")
                         if isinstance(dll, bytes) else str(dll))
    return names


def pe_imports(data: bytes, pefile) -> list:
    """The DLL names one PE image imports, normally AND by delay load."""
    image = pefile.PE(data=data, fast_load=True)
    image.parse_data_directories(directories=[
        pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_IMPORT"],
        pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT"],
    ])
    names = names_from(image)
    image.close()
    return names


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wheel")
    parser.add_argument("pattern",
                        help="regex a vendored member's name must match")
    parser.add_argument("--tooling", default="",
                        help="directory holding the repair tool (and pefile)")
    parser.add_argument("--forbid", action="append", default=[],
                        help="a DLL no extension may still import by bare name")
    args = parser.parse_args(argv)

    archive = zipfile.ZipFile(args.wheel)
    names = archive.namelist()
    if not vendored(names, args.pattern):
        print("nothing matching %s was vendored into %s"
              % (args.pattern, args.wheel), file=sys.stderr)
        return 1
    if not args.forbid:
        return 0

    images = pe_members(names)
    if not images:
        return 0

    if args.tooling:
        sys.path.insert(0, args.tooling)
    try:
        import pefile  # noqa: PLC0415 — only needed when there is a PE to read
    except ImportError as exc:
        print("cannot read import tables: pefile is not importable from %r "
              "(%s); the repair cannot be proven" % (args.tooling, exc),
              file=sys.stderr)
        return 2

    for name in images:
        try:
            still = offending(pe_imports(archive.read(name), pefile),
                              args.forbid)
        except Exception as exc:  # noqa: BLE001 — a member that is not a PE
            print("cannot read the import table of %s: %s" % (name, exc),
                  file=sys.stderr)
            return 2
        if still:
            print("%s still imports %s from the machine rather than from the "
                  "wheel: the repair did not rebind it"
                  % (name, ", ".join(still)), file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""Report a fresh Linux dependency resolve; never change the runtime lock."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from gen_notice import canonical_name, read_lock_vars, read_manifest


def main() -> int:
    scripts = Path(__file__).resolve().parent
    roots = [pin.split("==", 1)[0] for pin in
             read_lock_vars(scripts / "runtime-bundle.lock")["PIP_PKGS"].split()]
    summary = ["## CAD upstream runtime drift (Linux)", "",
               "Unconstrained root and transitive versions; report only.", ""]
    with tempfile.TemporaryDirectory(prefix="cad-drift-") as scratch:
        report = Path(scratch) / "report.json"
        result = subprocess.run(
            [sys.executable, "-m", "pip", "install", "--dry-run",
             "--ignore-installed", "--only-binary=:all:", "--disable-pip-version-check",
             "--report", str(report), *roots],
            capture_output=True, text=True, check=False)
        if result.returncode:
            summary += ["**Resolver failed; drift is unknown.**", "", "```text",
                        (result.stdout + result.stderr)[-12000:], "```"]
        else:
            resolved = {canonical_name(entry["metadata"]["name"]):
                        entry["metadata"]["version"]
                        for entry in json.loads(report.read_text())["install"]}
            census = read_manifest(scripts / "runtime-bundle.manifest")
            changes = [f"| {name} | {census.get(name, 'new')} | {version} |"
                       for name, version in sorted(resolved.items())
                       if census.get(name) != version]
            if changes:
                summary += ["| Distribution | Locked | Upstream resolve |",
                            "| --- | --- | --- |", *changes]
            else:
                summary.append("No version drift in this Linux dependency resolve.")
            absent = sorted(census.keys() - resolved.keys())
            if absent:
                summary += ["", "Outside this Linux dependency resolve "
                            "(platform-only, bootstrap or no-deps packages): "
                            + ", ".join(absent) + "."]
    text = "\n".join(summary) + "\n"
    print(text)
    destination = os.environ.get("GITHUB_STEP_SUMMARY")
    if destination:
        with Path(destination).open("a", encoding="utf-8") as output:
            output.write(text)
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())

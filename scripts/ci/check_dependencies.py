"""Keep Go consumers, CI and the source-install contract coherent."""
from __future__ import annotations

import json
import re
from pathlib import Path

import yaml

GO_MODULES = ("shared", "codetools", "cad", "docket", "multimeter", "pcb")
COMPRESS_MIN_GO = (1, 25, 0)


def go_version(text: str) -> tuple[int, int, int]:
    if not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", text):
        raise ValueError(f"invalid Go version {text!r}")
    parts = [int(part) for part in text.split(".")]
    return parts[0], parts[1], parts[2] if len(parts) == 3 else 0


def check_dependencies(root: Path) -> list[str]:
    errors: list[str] = []
    versions: dict[str, str] = {}
    for module in GO_MODULES:
        text = (root / module / "go.mod").read_text(encoding="utf-8")
        match = re.search(r"(?m)^\s*(?:require\s+)?github.com/klauspost/compress\s+(v\S+)", text)
        if match is None:
            errors.append(f"{module}/go.mod: missing compress requirement")
        else:
            versions[module] = match[1]
        directive = re.search(r"(?m)^go (\S+)$", text)
        if directive is None or go_version(directive[1]) < COMPRESS_MIN_GO:
            errors.append(f"{module}/go.mod: compress requires Go 1.25.0 or newer")
        if re.search(r"(?m)^toolchain\s", text):
            errors.append(f"{module}/go.mod: CI toolchain belongs only in .go-version")
    if len(set(versions.values())) != 1:
        errors.append(f"compress requirements differ: {versions}")
    ci_version = go_version((root / ".go-version").read_text(encoding="utf-8").strip())
    if ci_version < COMPRESS_MIN_GO:
        errors.append(".go-version: CI is older than compress's Go minimum")
    manifest = json.loads((root / "docket/manifest.json").read_text(encoding="utf-8"))
    advertised = next((item["min"] for item in manifest["setup"]["requires"]
                       if item["tool"] == "go"), "0.0")
    if go_version(advertised) != COMPRESS_MIN_GO:
        errors.append("docket/manifest.json: advertise the Go 1.25 source-build minimum")
    if "Requires Go 1.25 or newer" not in manifest["description"]:
        errors.append("docket/manifest.json: description disagrees with the setup minimum")

    for path in sorted((root / ".github").rglob("*.y*ml")):
        # GitHub's YAML payload is dynamic; inspect only known job/composite step lists.
        data = yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
        if not isinstance(data, dict):
            continue
        groups = [job.get("steps", []) for job in data.get("jobs", {}).values()]
        groups.append(data.get("runs", {}).get("steps", []))
        for steps in groups:
            for step in steps:
                if str(step.get("uses", "")).startswith("actions/setup-go@"):
                    inputs = step.get("with", {})
                    if "go-version" in inputs or inputs.get("go-version-file") != ".go-version":
                        errors.append(f"{path.relative_to(root)}: setup-go must read .go-version")
    return errors


if __name__ == "__main__":
    problems = check_dependencies(Path("."))
    for problem in problems:
        print(problem)
    print(f"Dependency coherence: {len(problems)} violations")
    raise SystemExit(bool(problems))

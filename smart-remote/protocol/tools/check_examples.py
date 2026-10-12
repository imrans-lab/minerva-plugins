#!/usr/bin/env python3
"""Validate every protocol example against the schemas and the framing rules in protocol.md.

Example files are JSONL. Each line is one frame:
  {"dir": "d2p" | "p2d", "msg": {...}}                       a control message
  {"dir": "d2p" | "p2d", "audio": "<header hex>", "bytes": N}  an audio frame, N payload bytes
Exit status is non-zero on the first file with any failure; every failure is printed.
"""
import json
import pathlib
import sys

from jsonschema import Draft202012Validator
from referencing import Registry, Resource

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCHEMA = ROOT / "schema"
DIRS = {"d2p": "device", "p2d": "plugin"}
KIND_DIR = {1: "d2p", 2: "p2d"}
MAX_AUDIO = 4096


def load_validators():
    resources = []
    for path in SCHEMA.rglob("*.json"):
        doc = json.loads(path.read_text())
        resources.append((doc["$id"], Resource.from_contents(doc)))
    registry = Registry().with_resources(resources)
    validators = {}
    for d, sub in DIRS.items():
        for path in (SCHEMA / sub).glob("*.json"):
            doc = json.loads(path.read_text())
            Draft202012Validator.check_schema(doc)
            validators[(d, path.stem)] = Draft202012Validator(doc, registry=registry)
    return validators


def parse_header(hexstr):
    raw = bytes.fromhex(hexstr)
    if len(raw) != 4:
        raise ValueError(f"header is {len(raw)} bytes, want 4")
    kind = raw[0] & 0x0F
    if raw[0] & 0x70:
        raise ValueError("reserved header bits set")
    return kind, bool(raw[0] & 0x80), raw[1], int.from_bytes(raw[2:4], "little")


def check_file(path, validators):
    errors = []
    first = {}
    announced = {}  # kind -> stream id announced by ptt_down / speak
    next_seq = {}  # (kind, stream) -> expected seq; deleted at EOS
    for n, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip():
            continue
        where = f"{path.name}:{n}"
        frame = json.loads(line)
        d = frame.get("dir")
        if d not in DIRS:
            errors.append(f"{where}: bad dir {d!r}")
            continue
        if "msg" in frame:
            msg = frame["msg"]
            t = msg.get("type")
            v = validators.get((d, t))
            if v is None:
                errors.append(f"{where}: no {DIRS[d]} schema for type {t!r}")
                continue
            errors += [f"{where}: {t}: {e.message}" for e in v.iter_errors(msg)]
            first.setdefault(d, t)
            if t == "ptt_down":
                announced[1] = msg["stream"]
            elif t == "speak":
                announced[2] = msg["stream"]
            elif t == "ptt_up" and (1, msg["stream"]) in next_seq:
                errors.append(f"{where}: ptt_up before the EOS mic frame")
            continue
        try:
            kind, eos, stream, seq = parse_header(frame["audio"])
        except (KeyError, ValueError) as e:
            errors.append(f"{where}: audio header: {e}")
            continue
        size = frame.get("bytes", 0)
        if KIND_DIR.get(kind) != d:
            errors.append(f"{where}: audio kind {kind} not allowed in {d}")
        if size % 2 or size > MAX_AUDIO:
            errors.append(f"{where}: payload {size} bytes is odd or over {MAX_AUDIO}")
        if announced.get(kind) != stream:
            errors.append(f"{where}: stream {stream} was not announced")
        want = next_seq.get((kind, stream), 0)
        if seq != want:
            errors.append(f"{where}: seq {seq}, want {want}")
        if eos:
            next_seq.pop((kind, stream), None)
        else:
            next_seq[(kind, stream)] = (seq + 1) % 65536
    if first.get("d2p", "hello") != "hello":
        errors.append(f"{path.name}: first device message is {first['d2p']}, want hello")
    if first.get("p2d", "welcome") not in ("welcome", "error"):
        errors.append(f"{path.name}: first plugin message is {first['p2d']}, want welcome or error")
    errors += [f"{path.name}: stream kind {k} id {s} never ended with EOS" for k, s in next_seq]
    return errors


def main():
    validators = load_validators()
    files = sorted((ROOT / "examples").glob("*.jsonl"))
    if not files:
        print("no examples found", file=sys.stderr)
        return 1
    failed = False
    for path in files:
        errors = check_file(path, validators)
        print(f"{'FAIL' if errors else 'ok  '} {path.name}")
        for e in errors:
            print(f"     {e}")
        failed |= bool(errors)
    # Each invalid example breaks exactly one rule; a checker that accepts one has lost that rule.
    for path in sorted((ROOT / "examples" / "invalid").glob("*.jsonl")):
        errors = check_file(path, validators)
        print(f"{'ok  ' if errors else 'FAIL'} invalid/{path.name} {'rejected' if errors else 'was accepted'}")
        failed |= not errors
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

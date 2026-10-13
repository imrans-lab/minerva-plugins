#!/usr/bin/env python3
"""Focused writer gate; run inside the qualification container, never the host."""
from pathlib import Path
import json
import re
import subprocess
import sys


EXIT_TABLE = """state | cancel | timeout | disconnect/reconnect | revoke | host crash
recording | input_cancel + terminal mic_state |300s too_long|cancel old session, serialize endpoint, re-send draft|visible permission failure/close|EOF closes caller; host removes endpoint
transcribing |known session input_cancel + idle/error|125s transcribe_timeout|late transcript ignored; old outstanding call cancelled|visible refusal/close|EOF cannot issue unregister on closed RPC
sending |host owns admitted turn|35s submit failure|exact send/chat origin; bound draft retained|target_changed or permission failure|no reply invented
speaking |device PTT empty EOS; host abort flush/mute|300s unknown drain fails|negative completion, stale ACK ignored|failure visible, unavailable endpoint|no synthetic playback success
idle/draft |Clear echoes empty draft|5s control refusal|per-device bound draft restored; focus mismatch refuses Send|registration failure closes visibly|restart requires a fresh known draft
Transport fixtures assert actual PCM bytes, cancellation states, outstanding-call bounds, reconnect and pacing. Physical DMA/live service are separate gates."""

def inventory(base: str, pin: str) -> int:
    repo = Path(__file__).resolve().parents[2]
    def git(*args: str) -> str:
        return subprocess.check_output(["git", "-C", str(repo), *args], text=True)
    names = [row.split("\t") for row in git("diff", "--name-status", "--no-renames", base, pin).splitlines()]
    allowed_files = {"scripts/build_plugin_from_manifest.py", "scripts/check_manifest_producer.py", "smart-remote/Cargo.toml", "smart-remote/Cargo.lock", "smart-remote/manifest.json", "smart-remote/README.md", "smart-remote/protocol/protocol.md", "smart-remote/protocol/tools/check_examples.py", "smart-remote/protocol/schema/device/speak_done.json", "smart-remote/protocol/schema/plugin/speak.json", "smart-remote/protocol/schema/plugin/error.json", "smart-remote/scripts/writer_self_check.py"}
    allowed_files.update("smart-remote/src/" + name + ".rs" for name in ("host", "main", "server", "session", "audio", "message", "lib", "bridge", "resample"))
    allowed = lambda path: path in allowed_files or path.startswith(("smart-remote/tests/", "smart-remote/protocol/examples/"))
    unexpected = [row for row in names if not allowed(row[-1])]
    removed = [row for row in names if row[0] == "D" and ("test" in row[-1] or "examples" in row[-1])]
    test_pattern = re.compile(r"#\[(?:tokio::)?test[^]]*]\s*(?:async\s+)?fn\s+(\w+)")
    candidates, owners = [], []
    for _, path in names:
        if not path.endswith(".rs") or not path.startswith("smart-remote/src/") and "test" not in path:
            continue
        before = git("show", base + ":" + path) if git("ls-tree", base, "--", path) else ""
        after = git("show", pin + ":" + path) if git("ls-tree", pin, "--", path) else ""
        removed += [{"path": path, "test": name} for name in set(test_pattern.findall(before)) - set(test_pattern.findall(after))]
        for number, line in enumerate(after.splitlines(), 1):
            if re.search(r"log::(?:warn|error)!", line):
                candidates.append({"path": path, "line": number, "candidate": line.strip(), "semantic_review": "confirm OLED/caller surfacing or documented closed-transport boundary"})
        production = after.split("#[cfg(test)]")[0]
        if re.search(r"fs::(?:write|rename)|fn persist\(", production):
            owners.append(path)
    # TokenStore is the sole persisted pairing-setting writer; process-memory draft is transient.
    setting_files = git("ls-tree", "-r", "--name-only", pin, "--", "smart-remote/src").splitlines()
    setting_owners = [path for path in setting_files if "fn persist(" in git("show", pin + ":" + path).split("#[cfg(test)]")[0]]
    report = {"exit_path_table": EXIT_TABLE, "base": git("rev-parse", base).strip(), "pin": git("rev-parse", pin).strip(), "card_touch_set_diff": names, "unexpected_paths": unexpected, "deleted_or_renamed_tests": removed, "logged_failure_candidates": candidates, "changed_setting_writers": owners, "persisted_setting_owners": setting_owners}
    print(json.dumps(report, indent=2))
    return int(bool(unexpected or removed or setting_owners != ["smart-remote/src/store.rs"]))


def main() -> int:
    if len(sys.argv) == 4 and sys.argv[1] == "--inventory":
        return inventory(sys.argv[2], sys.argv[3])
    if len(sys.argv) != 1:
        raise SystemExit("usage: writer_self_check.py [--inventory BASE PIN]")
    root = Path(__file__).resolve().parents[1]
    print(EXIT_TABLE, flush=True)
    commands = [
        ["cargo", "fmt", "--check"],
        ["cargo", "clippy", "--locked", "--all-targets", "--", "-D", "warnings"],
        ["cargo", "test", "--locked", "--", "--nocapture"],
        [sys.executable, "protocol/tools/check_examples.py"],
    ]
    for command in commands:
        print("CHECK", " ".join(command), flush=True)
        subprocess.run(command, cwd=root, check=True, timeout=300)
    print("Writer checks PASS including full cargo test; native Windows/live-service/physical playback remain separate.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

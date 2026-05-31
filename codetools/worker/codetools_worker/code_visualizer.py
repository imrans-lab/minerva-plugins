"""Code-visualizer (vendored code-magic) → unified envelope adapter.

P1.3 wraps the 9 code-magic MCP tools as `minerva_codetools_*` methods on the
codetools worker. Each handler:

  - imports from `vendored.code_visualizer.analyzer.*` (snapshot @9cc9403);
  - opens the SQLite store at the requested path (per-call `db_path` overrides
    the `CODETOOLS_DB` env var; required — no implicit default);
  - returns `envelope.ok(summary, artifacts=[{"type": ..., ...}])`. A single-
    answer tool ships a one-element artifacts list; multi-row tools ship one
    artifact per row OR a single container artifact whose type names the shape
    (decided per tool, kept simple).

Why an adapter file instead of editing vendored source: pickup.md + DCR comment
381 — vendored/ is hermetic. Adapters absorb every shape mismatch.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

from . import envelope
from .errors import ToolError

# Vendored analyzer modules (snapshot @9cc9403 — do not edit upstream).
from vendored.code_visualizer.analyzer.store import CodeMagicStore

DB_ENV_VAR = "CODETOOLS_DB"


def _resolve_db_path(params):
    """Return the SQLite path: explicit `db_path` param > env > ToolError."""
    db_path = params.get("db_path")
    if not db_path:
        db_path = os.environ.get(DB_ENV_VAR)
    if not db_path:
        raise ToolError(
            "no db_path provided and %s is unset" % DB_ENV_VAR,
            kind="invalid_args",
        )
    if not isinstance(db_path, str):
        raise ToolError("db_path must be a string", kind="invalid_args")
    return db_path


def _open_store(params):
    """Open the CodeMagicStore for this call. Caller releases on return."""
    db_path = _resolve_db_path(params)
    # CodeMagicStore raises sqlite3.OperationalError if the path is unwritable
    # or the schema can't be initialised; let it propagate to the dispatcher as
    # an internal error rather than swallowing.
    return CodeMagicStore(db_path)


def _format_context(ctx):
    """Same shape as the original code-magic _format_context — kept stable so
    agents/tests trained on the upstream API see no surprises."""
    sym = ctx["symbol"]
    f = ctx.get("file")
    return {
        "symbol": {
            "id": sym["id"],
            "name": sym["name"],
            "kind": sym["kind"],
            "signature": sym["signature"],
            "description": sym["description"],
            "is_entry_point": bool(sym["is_entry_point"]),
            "file": f["relative_path"] if f else "",
            "lines": "%d-%d" % (sym["line_start"], sym["line_end"]),
        },
        "incoming_edges": [
            {"from": e["name"], "kind": e["kind"], "type": e["edge_type"],
             "file": e["relative_path"], "confidence": e["confidence"]}
            for e in ctx["incoming_edges"]
        ],
        "outgoing_edges": [
            {"to": e["name"], "kind": e["kind"], "type": e["edge_type"],
             "file": e["relative_path"], "confidence": e["confidence"]}
            for e in ctx["outgoing_edges"]
        ],
        "tags": [{"name": t["tag_name"], "value": t["tag_value"]}
                 for t in ctx["tags"]],
    }


# ---------------------------------------------------------------------------
# 1. query — full-text + name search
# ---------------------------------------------------------------------------

def query(params):
    q = params.get("query")
    if not q or not isinstance(q, str):
        raise ToolError("query must be a non-empty string", kind="invalid_args")
    scope = params.get("scope", "symbols")
    if scope not in ("symbols", "files"):
        raise ToolError("scope must be 'symbols' or 'files'", kind="invalid_args")

    store = _open_store(params)
    fts = store.search(q, limit=20)

    rows = store.conn.execute(
        """SELECT s.*, f.relative_path FROM symbols s
           JOIN files f ON s.file_id = f.id
           WHERE s.name = ? LIMIT 10""", (q,)).fetchall()
    name_matches = [dict(r) for r in rows]
    if not name_matches:
        rows = store.conn.execute(
            """SELECT s.*, f.relative_path FROM symbols s
               JOIN files f ON s.file_id = f.id
               WHERE s.name LIKE ? LIMIT 10""", (f"%{q}%",)).fetchall()
        name_matches = [dict(r) for r in rows]

    if scope == "files":
        fts = [r for r in fts if r.get("entity_type") == "file"]
    else:
        fts = [r for r in fts if r.get("entity_type") == "symbol"]

    seen = set()
    results = []
    for m in name_matches:
        mid = m.get("id", "")
        if mid in seen:
            continue
        seen.add(mid)
        results.append({
            "id": mid,
            "name": m.get("name", ""),
            "kind": m.get("kind", ""),
            "signature": m.get("signature", ""),
            "file": m.get("relative_path", ""),
            "lines": "%d-%d" % (m.get("line_start", 0), m.get("line_end", 0)),
            "description": m.get("description", ""),
            "match_type": "name",
        })
    for r in fts:
        eid = r.get("entity_id", "")
        if eid in seen:
            continue
        seen.add(eid)
        # Row key is `entity_type`, NOT upstream's `type`. The outer artifact
        # already carries `"type": "query_results"`; reusing `type` on a row
        # would collide with the envelope's typed-artifact discriminator.
        results.append({
            "id": eid,
            "name": r.get("name", ""),
            "entity_type": r.get("entity_type", ""),
            "description": (r.get("description") or "")[:200],
            "match_type": "fts",
        })

    return envelope.ok(
        "query %r matched %d result(s) (scope=%s)" % (q, len(results), scope),
        artifacts=[{"type": "query_results", "query": q, "scope": scope,
                    "count": len(results), "results": results}],
    )


# ---------------------------------------------------------------------------
# 2. get_context — full context for a symbol or file
# ---------------------------------------------------------------------------

def get_context(params):
    identifier = params.get("identifier")
    if not identifier or not isinstance(identifier, str):
        raise ToolError("identifier must be a non-empty string", kind="invalid_args")
    store = _open_store(params)

    sym = store.get_symbol(identifier)
    if sym:
        ctx = store.get_context(identifier)
        formatted = _format_context(ctx)
        return envelope.ok(
            "context for symbol %s (%s)" % (sym["name"], sym["kind"]),
            artifacts=[{"type": "code_context", "kind": "symbol", **formatted}],
        )

    matches = store.get_symbol_by_name(identifier)
    if matches:
        if len(matches) == 1:
            ctx = store.get_context(matches[0]["id"])
            formatted = _format_context(ctx)
            return envelope.ok(
                "context for symbol %s (%s)" % (formatted["symbol"]["name"],
                                                formatted["symbol"]["kind"]),
                artifacts=[{"type": "code_context", "kind": "symbol", **formatted}],
            )
        return envelope.ok(
            "multiple symbols named %r (%d)" % (identifier, len(matches)),
            artifacts=[{
                "type": "symbol_disambiguation",
                "name": identifier,
                "matches": [
                    {"id": m["id"], "kind": m["kind"], "signature": m["signature"],
                     "file": _file_path(store, m["file_id"]),
                     "line": m["line_start"]}
                    for m in matches
                ],
            }],
        )

    file_info = store.get_file_by_path(identifier)
    if file_info:
        symbols = store.get_symbols_in_file(file_info["id"])
        return envelope.ok(
            "context for file %s (%d symbol(s))" % (file_info["relative_path"],
                                                     len(symbols)),
            artifacts=[{
                "type": "code_context",
                "kind": "file",
                "file": {
                    "path": file_info["relative_path"],
                    "description": file_info["description"],
                    "line_count": file_info["line_count"],
                    "git_hash": (file_info["last_analyzed_git_hash"] or "")[:8],
                },
                "symbols": [
                    {"name": s["name"], "kind": s["kind"], "signature": s["signature"],
                     "lines": "%d-%d" % (s["line_start"], s["line_end"]),
                     "description": s["description"],
                     "is_entry_point": bool(s["is_entry_point"])}
                    for s in symbols
                ],
            }],
        )

    raise ToolError("no symbol or file found for %r" % identifier, kind="not_found")


def _file_path(store, file_id):
    f = store.get_file(file_id)
    return f["relative_path"] if f else ""


# ---------------------------------------------------------------------------
# 3. stale_check — files changed since last index
# ---------------------------------------------------------------------------

def stale_check(params):
    project_filter = params.get("project", "")
    store = _open_store(params)

    projects = store.list_projects()
    if project_filter:
        projects = [p for p in projects if p["name"] == project_filter]

    stale = []
    for proj in projects:
        files = store.list_files(proj["id"])
        for f in files:
            full = Path(proj["path"]) / f["relative_path"]
            if not full.exists():
                stale.append({"file": f["relative_path"], "status": "deleted",
                              "project": proj["name"]})
                continue
            try:
                result = subprocess.run(
                    ["git", "log", "-1", "--format=%H", "--", str(full)],
                    capture_output=True, text=True, cwd=proj["path"], timeout=5)
                current_hash = result.stdout.strip()
                if current_hash != f["last_analyzed_git_hash"]:
                    stale.append({
                        "file": f["relative_path"],
                        "status": "modified",
                        "project": proj["name"],
                        "indexed_hash": (f["last_analyzed_git_hash"] or "")[:8],
                        "current_hash": current_hash[:8],
                    })
            except Exception:
                stale.append({"file": f["relative_path"], "status": "unknown",
                              "project": proj["name"]})

    return envelope.ok(
        "%d file(s) stale" % len(stale) if stale else "all indexed files up to date",
        artifacts=[{"type": "stale_check", "stale_count": len(stale),
                    "files": stale, "project_filter": project_filter}],
    )


# ---------------------------------------------------------------------------
# 4. get_diff — git diff between refs as structured data
# ---------------------------------------------------------------------------

def get_diff(params):
    base = params.get("base", "HEAD")
    head = params.get("head", "")
    file = params.get("file", "")
    repo_path = params.get("repo_path", "")

    if not repo_path:
        store = _open_store(params)
        projects = store.list_projects()
        if projects:
            repo_path = projects[0]["path"]
        else:
            raise ToolError(
                "no repo_path provided and no projects in the store to infer one",
                kind="invalid_args",
            )

    repo_path = str(repo_path)

    def run_git(*args, allow_fail=False):
        result = subprocess.run(
            ["git"] + list(args),
            capture_output=True, text=True, cwd=repo_path, timeout=15)
        if result.returncode != 0 and not allow_fail:
            return None, result.stderr.strip()
        return result.stdout, None

    status_map = {"M": "modified", "A": "added", "D": "deleted",
                  "R": "renamed", "C": "copied"}
    changed = {}

    if head == "":
        for extra in ([], ["--cached"]):
            cmd = ["diff", "--name-status"] + extra + [base]
            if file:
                cmd += ["--", file]
            out, err = run_git(*cmd)
            if err is not None:
                raise ToolError("git diff failed: %s" % err, kind="git_error")
            for line in (out or "").splitlines():
                line = line.strip()
                if not line:
                    continue
                parts = line.split("\t", 1)
                if len(parts) == 2:
                    changed[parts[1]] = status_map.get(parts[0][0], "modified")
    else:
        cmd = ["diff", "--name-status", "%s..%s" % (base, head)]
        if file:
            cmd += ["--", file]
        out, err = run_git(*cmd)
        if err is not None:
            raise ToolError("git diff failed: %s" % err, kind="git_error")
        for line in (out or "").splitlines():
            line = line.strip()
            if not line:
                continue
            parts = line.split("\t", 1)
            if len(parts) == 2:
                changed[parts[1]] = status_map.get(parts[0][0], "modified")

    files = []
    for path, status in changed.items():
        if status == "added":
            before = ""
        else:
            b_out, _ = run_git("show", "%s:%s" % (base, path), allow_fail=True)
            before = b_out if b_out is not None else ""
        if status == "deleted":
            after = ""
        elif head == "":
            full = Path(repo_path) / path
            try:
                after = full.read_text(encoding="utf-8", errors="replace")
            except Exception:
                after = ""
        else:
            a_out, _ = run_git("show", "%s:%s" % (head, path), allow_fail=True)
            after = a_out if a_out is not None else ""
        files.append({"path": path, "status": status,
                      "before_content": before, "after_content": after})

    head_label = head if head else "working tree"
    return envelope.ok(
        "%d file(s) changed between %s and %s" % (len(files), base, head_label),
        artifacts=[{"type": "diff", "base": base, "head": head_label,
                    "files": files}],
    )


# ---------------------------------------------------------------------------
# 5. analyze — higher-level rollups
# ---------------------------------------------------------------------------

_ANALYZE_KINDS = ("dead_code", "dry_candidates", "coupling_hotspots", "stats")


def analyze(params):
    kind = params.get("analysis")
    if kind not in _ANALYZE_KINDS:
        raise ToolError(
            "analysis must be one of: %s" % ", ".join(_ANALYZE_KINDS),
            kind="invalid_args",
        )
    store = _open_store(params)

    if kind == "dead_code":
        candidates = store.dead_code_candidates()
        by_file = {}
        for c in candidates:
            by_file.setdefault(c["relative_path"], []).append({
                "name": c["name"], "kind": c["kind"], "line": c["line_start"],
                "signature": c.get("signature", ""),
            })
        return envelope.ok(
            "%d dead-code candidate(s) across %d file(s)" % (len(candidates), len(by_file)),
            artifacts=[{
                "type": "analysis", "analysis": "dead_code",
                "description": "Symbols with zero incoming edges and not entry points. "
                               "May be unused; verify — some are called dynamically.",
                "total_candidates": len(candidates), "by_file": by_file,
            }],
        )

    if kind == "dry_candidates":
        candidates = store.dry_candidates()
        return envelope.ok(
            "%d DRY-candidate group(s)" % len(candidates),
            artifacts=[{
                "type": "analysis", "analysis": "dry_candidates",
                "description": "Groups of functions sharing the same signature hash. "
                               "May indicate duplication.",
                "groups": [
                    {"signature_hash": c["signature_hash"], "count": c["count"],
                     "names": c["names"], "locations": c["locations"]}
                    for c in candidates[:20]
                ],
            }],
        )

    if kind == "coupling_hotspots":
        hotspots = store.coupling_hotspots(limit=20)
        return envelope.ok(
            "%d coupling hotspot(s)" % len(hotspots),
            artifacts=[{
                "type": "analysis", "analysis": "coupling_hotspots",
                "description": "Symbols with the most outgoing edges. High fan-out = tight coupling.",
                "hotspots": [
                    {"name": h["name"], "kind": h["kind"], "file": h["relative_path"],
                     "fan_out": h["fan_out"]} for h in hotspots
                ],
            }],
        )

    # kind == "stats"
    stats = store.stats()
    return envelope.ok(
        "store stats: %s" % ", ".join("%s=%s" % (k, v) for k, v in stats.items()),
        artifacts=[{"type": "analysis", "analysis": "stats", **stats}],
    )


# ---------------------------------------------------------------------------
# 6. set_description — symbol or file
# ---------------------------------------------------------------------------

def set_description(params):
    item_id = params.get("id")
    description = params.get("description")
    entity_type = params.get("entity_type", "symbol")
    if not item_id or not isinstance(item_id, str):
        raise ToolError("id must be a non-empty string", kind="invalid_args")
    if description is None or not isinstance(description, str):
        raise ToolError("description must be a string", kind="invalid_args")
    if entity_type not in ("symbol", "file"):
        raise ToolError("entity_type must be 'symbol' or 'file'", kind="invalid_args")

    store = _open_store(params)
    if entity_type == "symbol":
        sym = store.get_symbol(item_id)
        if not sym:
            raise ToolError("symbol %s not found" % item_id, kind="not_found")
        store.set_description("symbol", item_id, description)
        return envelope.ok(
            "description set on symbol %s" % sym["name"],
            artifacts=[{"type": "description_set", "entity_type": "symbol",
                        "id": item_id, "name": sym["name"]}],
        )
    f = store.get_file(item_id)
    if not f:
        raise ToolError("file %s not found" % item_id, kind="not_found")
    store.set_description("file", item_id, description)
    return envelope.ok(
        "description set on file %s" % f["relative_path"],
        artifacts=[{"type": "description_set", "entity_type": "file",
                    "id": item_id, "path": f["relative_path"]}],
    )


# ---------------------------------------------------------------------------
# 7. describe_symbol — description + tags in one call
# ---------------------------------------------------------------------------

def describe_symbol(params):
    # `tags_added` artifact field is the LIST of tags applied — upstream
    # returned an int count. The list is more useful to an agent loop and
    # carries the count implicitly; document the divergence here.
    item_id = params.get("id")
    description = params.get("description")
    tags = params.get("tags", "")
    if not item_id or not isinstance(item_id, str):
        raise ToolError("id must be a non-empty string", kind="invalid_args")
    if description is None or not isinstance(description, str):
        raise ToolError("description must be a string", kind="invalid_args")
    if not isinstance(tags, str):
        raise ToolError("tags must be a comma-separated string", kind="invalid_args")

    store = _open_store(params)
    sym = store.get_symbol(item_id)
    if not sym:
        raise ToolError("symbol %s not found" % item_id, kind="not_found")
    store.set_description("symbol", item_id, description)

    tag_list = [t.strip() for t in tags.split(",") if t.strip()] if tags else []
    for tag in tag_list:
        store.add_tag("symbol", item_id, tag)

    return envelope.ok(
        "described symbol %s (%d tag(s) added)" % (sym["name"], len(tag_list)),
        artifacts=[{"type": "symbol_described", "id": item_id, "name": sym["name"],
                    "tags_added": tag_list}],
    )


# ---------------------------------------------------------------------------
# 8. set_tags — tags on a symbol or file
# ---------------------------------------------------------------------------

def set_tags(params):
    item_id = params.get("id")
    tags = params.get("tags", "")
    entity_type = params.get("entity_type", "symbol")
    if not item_id or not isinstance(item_id, str):
        raise ToolError("id must be a non-empty string", kind="invalid_args")
    if not isinstance(tags, str):
        raise ToolError("tags must be a comma-separated string", kind="invalid_args")
    if entity_type not in ("symbol", "file"):
        raise ToolError("entity_type must be 'symbol' or 'file'", kind="invalid_args")

    store = _open_store(params)
    tag_list = [t.strip() for t in tags.split(",") if t.strip()] if tags else []
    for tag in tag_list:
        store.add_tag(entity_type, item_id, tag)
    return envelope.ok(
        "%d tag(s) set on %s %s" % (len(tag_list), entity_type, item_id),
        artifacts=[{"type": "tags_set", "entity_type": entity_type, "id": item_id,
                    "tags_added": tag_list}],
    )


# ---------------------------------------------------------------------------
# 9. undescribed — list items still needing descriptions
# ---------------------------------------------------------------------------

def undescribed(params):
    entity_type = params.get("entity_type", "symbol")
    limit = params.get("limit", 20)
    if entity_type not in ("symbol", "file"):
        raise ToolError("entity_type must be 'symbol' or 'file'", kind="invalid_args")
    if not isinstance(limit, int) or limit < 1:
        raise ToolError("limit must be a positive integer", kind="invalid_args")

    store = _open_store(params)
    items = store.undescribed(entity_type, limit)

    if entity_type == "file":
        rows = [{"id": i["id"], "path": i["relative_path"],
                 "project": i["project_name"]} for i in items]
    else:
        rows = [{"id": i["id"], "name": i["name"], "kind": i["kind"],
                 "file": i["relative_path"],
                 "lines": "%d-%d" % (i["line_start"], i["line_end"]),
                 "project": i["project_name"]} for i in items]

    return envelope.ok(
        "%d undescribed %s(s) (limit=%d)" % (len(rows), entity_type, limit),
        artifacts=[{"type": "undescribed_items", "entity_type": entity_type,
                    "count": len(rows), "items": rows}],
    )

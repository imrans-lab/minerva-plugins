"""
code-magic MCP server.

Exposes the code knowledge store to Claude Code via MCP tools.

Usage:
    python -m server.mcp_server [--db <path>]
"""

import argparse
import json
import subprocess
import sys
import os
from pathlib import Path

from mcp.server.fastmcp import FastMCP

# Add parent to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))
from analyzer.store import CodeMagicStore

mcp = FastMCP("code-magic")

# Global store reference, initialized at startup
_store: CodeMagicStore = None


def _get_store() -> CodeMagicStore:
    global _store
    if _store is None:
        db_path = os.environ.get(
            "CODE_MAGIC_DB",
            str(Path(__file__).parent.parent / "data" / "code-magic.db"))
        _store = CodeMagicStore(db_path)
    return _store


@mcp.tool()
def code_magic_query(query: str, project: str = "", scope: str = "symbols") -> str:
    """Search the code knowledge store by text.

    Full-text search across symbol and file descriptions, plus name matching.

    Args:
        query: Search text (matched against descriptions and names)
        project: Optional project name to scope search
        scope: "symbols" or "files" (default: "symbols")
    """
    store = _get_store()

    # Try FTS first
    results = store.search(query, limit=20)

    # Also try name matching (always join files for path)
    rows = store.conn.execute(
        """SELECT s.*, f.relative_path FROM symbols s
           JOIN files f ON s.file_id = f.id
           WHERE s.name = ? LIMIT 10""",
        (query,)).fetchall()
    name_matches = [dict(r) for r in rows]
    if not name_matches:
        # Try case-insensitive partial match
        rows = store.conn.execute(
            """SELECT s.*, f.relative_path FROM symbols s
               JOIN files f ON s.file_id = f.id
               WHERE s.name LIKE ? LIMIT 10""",
            (f"%{query}%",)).fetchall()
        name_matches = [dict(r) for r in rows]

    # Filter by scope
    if scope == "files":
        results = [r for r in results if r.get("entity_type") == "file"]
    else:
        results = [r for r in results if r.get("entity_type") == "symbol"]

    # Combine and deduplicate
    seen = set()
    output = []

    for match in name_matches:
        mid = match.get("id", "")
        if mid not in seen:
            seen.add(mid)
            output.append({
                "id": mid,
                "name": match.get("name", ""),
                "kind": match.get("kind", ""),
                "signature": match.get("signature", ""),
                "file": match.get("relative_path", ""),
                "lines": f"{match.get('line_start', 0)}-{match.get('line_end', 0)}",
                "description": match.get("description", ""),
                "match_type": "name",
            })

    for result in results:
        eid = result.get("entity_id", "")
        if eid not in seen:
            seen.add(eid)
            output.append({
                "id": eid,
                "name": result.get("name", ""),
                "type": result.get("entity_type", ""),
                "description": result.get("description", "")[:200],
                "match_type": "fts",
            })

    if not output:
        return json.dumps({"message": f"No results for '{query}'", "results": []})

    return json.dumps({"count": len(output), "results": output}, indent=2)


@mcp.tool()
def code_magic_get_context(identifier: str) -> str:
    """Get full context for a symbol or file.

    Returns description, incoming/outgoing edges, tags, file location.

    Args:
        identifier: Symbol name, symbol ID, or file relative path
    """
    store = _get_store()

    # Try as symbol ID first
    sym = store.get_symbol(identifier)
    if sym:
        ctx = store.get_context(identifier)
        return json.dumps(_format_context(ctx), indent=2)

    # Try as symbol name
    matches = store.get_symbol_by_name(identifier)
    if matches:
        if len(matches) == 1:
            ctx = store.get_context(matches[0]["id"])
            return json.dumps(_format_context(ctx), indent=2)
        else:
            # Multiple matches — return list for disambiguation
            return json.dumps({
                "message": f"Multiple symbols named '{identifier}'",
                "matches": [
                    {"id": m["id"], "kind": m["kind"], "signature": m["signature"],
                     "file": _get_file_path(store, m["file_id"]),
                     "line": m["line_start"]}
                    for m in matches
                ]
            }, indent=2)

    # Try as file path
    file_info = store.get_file_by_path(identifier)
    if file_info:
        symbols = store.get_symbols_in_file(file_info["id"])
        return json.dumps({
            "file": {
                "path": file_info["relative_path"],
                "description": file_info["description"],
                "line_count": file_info["line_count"],
                "git_hash": file_info["last_analyzed_git_hash"][:8],
            },
            "symbols": [
                {"name": s["name"], "kind": s["kind"], "signature": s["signature"],
                 "lines": f"{s['line_start']}-{s['line_end']}",
                 "description": s["description"],
                 "is_entry_point": bool(s["is_entry_point"])}
                for s in symbols
            ]
        }, indent=2)

    return json.dumps({"error": f"No symbol or file found for '{identifier}'"})


@mcp.tool()
def code_magic_stale_check(project: str = "") -> str:
    """Check which files have changed since last index.

    Compares stored git hashes against current repo state.

    Args:
        project: Optional project name (checks all if empty)
    """
    store = _get_store()

    projects = store.list_projects()
    if project:
        projects = [p for p in projects if p["name"] == project]

    stale = []
    for proj in projects:
        files = store.list_files(proj["id"])
        for f in files:
            full_path = Path(proj["path"]) / f["relative_path"]
            if not full_path.exists():
                stale.append({"file": f["relative_path"], "status": "deleted",
                              "project": proj["name"]})
                continue

            try:
                result = subprocess.run(
                    ["git", "log", "-1", "--format=%H", "--", str(full_path)],
                    capture_output=True, text=True, cwd=proj["path"], timeout=5)
                current_hash = result.stdout.strip()
                if current_hash != f["last_analyzed_git_hash"]:
                    stale.append({
                        "file": f["relative_path"],
                        "status": "modified",
                        "project": proj["name"],
                        "indexed_hash": f["last_analyzed_git_hash"][:8],
                        "current_hash": current_hash[:8],
                    })
            except Exception:
                stale.append({"file": f["relative_path"], "status": "unknown",
                              "project": proj["name"]})

    return json.dumps({
        "stale_count": len(stale),
        "files": stale,
        "message": "All files up to date" if not stale else f"{len(stale)} files need re-indexing"
    }, indent=2)


@mcp.tool()
def code_magic_get_diff(base: str = "HEAD", head: str = "", file: str = "",
                        repo_path: str = "") -> str:
    """Get git diff between two commits/refs as structured data.

    Returns changed files with before/after content for side-by-side comparison.

    Args:
        base: Base ref (default "HEAD"). Can be commit SHA, branch name, "HEAD~1", etc.
        head: Head ref (default "" = working tree for unstaged changes)
        file: Optional file path filter
        repo_path: Optional repo path (default: use CODE_MAGIC_DB path to infer)
    """
    # Determine repo path
    if not repo_path:
        store = _get_store()
        projects = store.list_projects()
        if projects:
            repo_path = projects[0]["path"]
        else:
            repo_path = os.getcwd()

    repo_path = str(repo_path)

    def run_git(*args, allow_fail: bool = False):
        result = subprocess.run(
            ["git"] + list(args),
            capture_output=True, text=True, cwd=repo_path, timeout=15)
        if result.returncode != 0 and not allow_fail:
            return None, result.stderr.strip()
        return result.stdout, None

    # Build list of changed files: {path: status}
    changed: dict[str, str] = {}

    if head == "":
        # Working tree mode: unstaged + staged
        for extra_args in ([], ["--cached"]):
            cmd = ["diff", "--name-status"] + extra_args + [base]
            if file:
                cmd += ["--", file]
            out, err = run_git(*cmd)
            if err is not None:
                return json.dumps({"error": f"git diff failed: {err}"})
            for line in (out or "").splitlines():
                line = line.strip()
                if not line:
                    continue
                parts = line.split("\t", 1)
                if len(parts) == 2:
                    status_char, path = parts[0][0], parts[1]
                    status_map = {"M": "modified", "A": "added", "D": "deleted",
                                  "R": "renamed", "C": "copied"}
                    changed[path] = status_map.get(status_char, "modified")
    else:
        # Commit-to-commit mode
        cmd = ["diff", "--name-status", f"{base}..{head}"]
        if file:
            cmd += ["--", file]
        out, err = run_git(*cmd)
        if err is not None:
            return json.dumps({"error": f"git diff failed: {err}"})
        for line in (out or "").splitlines():
            line = line.strip()
            if not line:
                continue
            parts = line.split("\t", 1)
            if len(parts) == 2:
                status_char, path = parts[0][0], parts[1]
                status_map = {"M": "modified", "A": "added", "D": "deleted",
                              "R": "renamed", "C": "copied"}
                changed[path] = status_map.get(status_char, "modified")

    # Build file entries with before/after content
    files = []
    for path, status in changed.items():
        # Before content: git show base:path
        if status == "added":
            before_content = ""
        else:
            before_out, _ = run_git("show", f"{base}:{path}", allow_fail=True)
            before_content = before_out if before_out is not None else ""

        # After content
        if status == "deleted":
            after_content = ""
        elif head == "":
            # Read from disk (working tree)
            full_path = Path(repo_path) / path
            try:
                after_content = full_path.read_text(encoding="utf-8", errors="replace")
            except Exception:
                after_content = ""
        else:
            after_out, _ = run_git("show", f"{head}:{path}", allow_fail=True)
            after_content = after_out if after_out is not None else ""

        files.append({
            "path": path,
            "status": status,
            "before_content": before_content,
            "after_content": after_content,
        })

    head_label = head if head else "working tree"
    return json.dumps({
        "base": base,
        "head": head_label,
        "files": files,
        "summary": f"{len(files)} file{'s' if len(files) != 1 else ''} changed",
    }, indent=2)


@mcp.tool()
def code_magic_analyze(analysis: str) -> str:
    """Run higher-level code analysis.

    Args:
        analysis: One of "dead_code", "dry_candidates", "coupling_hotspots", "stats"
    """
    store = _get_store()

    if analysis == "dead_code":
        candidates = store.dead_code_candidates()
        # Group by file
        by_file = {}
        for c in candidates:
            path = c["relative_path"]
            by_file.setdefault(path, []).append({
                "name": c["name"],
                "kind": c["kind"],
                "line": c["line_start"],
                "signature": c.get("signature", ""),
            })
        return json.dumps({
            "analysis": "dead_code",
            "description": "Symbols with zero incoming edges and not marked as entry points. "
                           "These may be unused, but verify — some may be called dynamically.",
            "total_candidates": len(candidates),
            "by_file": by_file,
        }, indent=2)

    elif analysis == "dry_candidates":
        candidates = store.dry_candidates()
        return json.dumps({
            "analysis": "dry_candidates",
            "description": "Groups of functions sharing the same signature hash "
                           "(same param count, types, return type). May indicate duplication.",
            "groups": [
                {"signature_hash": c["signature_hash"], "count": c["count"],
                 "names": c["names"], "locations": c["locations"]}
                for c in candidates[:20]
            ],
        }, indent=2)

    elif analysis == "coupling_hotspots":
        hotspots = store.coupling_hotspots(limit=20)
        return json.dumps({
            "analysis": "coupling_hotspots",
            "description": "Symbols with the most outgoing edges (calls to other symbols). "
                           "High fan-out indicates tight coupling.",
            "hotspots": [
                {"name": h["name"], "kind": h["kind"], "file": h["relative_path"],
                 "fan_out": h["fan_out"]}
                for h in hotspots
            ],
        }, indent=2)

    elif analysis == "stats":
        stats = store.stats()
        return json.dumps({"analysis": "stats", **stats}, indent=2)

    else:
        return json.dumps({
            "error": f"Unknown analysis type: {analysis}",
            "available": ["dead_code", "dry_candidates", "coupling_hotspots", "stats"]
        })


@mcp.tool()
def code_magic_set_description(id: str, description: str,
                               entity_type: str = "symbol") -> str:
    """Set the description for a symbol or file.

    Used by Claude Code to fill in descriptions interactively.

    Args:
        id: Symbol ID or file ID
        description: Natural language description
        entity_type: "symbol" or "file"
    """
    store = _get_store()

    if entity_type == "symbol":
        sym = store.get_symbol(id)
        if not sym:
            return json.dumps({"error": f"Symbol {id} not found"})
        store.set_description("symbol", id, description)
        return json.dumps({"ok": True, "name": sym["name"],
                           "message": f"Description set for symbol '{sym['name']}'"})
    elif entity_type == "file":
        f = store.get_file(id)
        if not f:
            return json.dumps({"error": f"File {id} not found"})
        store.set_description("file", id, description)
        return json.dumps({"ok": True, "path": f["relative_path"],
                           "message": f"Description set for file '{f['relative_path']}'"})
    else:
        return json.dumps({"error": f"Unknown entity_type: {entity_type}"})


@mcp.tool()
def code_magic_describe_symbol(id: str, description: str,
                                tags: str = "") -> str:
    """Set description and semantic tags for a symbol in one call.

    Args:
        id: Symbol ID
        description: Structured description (purpose, invariants, side effects, error behavior, gotchas)
        tags: Comma-separated semantic tags (e.g. "mutates_state,security_sensitive,does_io")
    """
    store = _get_store()
    sym = store.get_symbol(id)
    if not sym:
        return json.dumps({"error": f"Symbol {id} not found"})

    store.set_description("symbol", id, description)

    if tags:
        tag_list = [t.strip() for t in tags.split(",") if t.strip()]
        for tag in tag_list:
            store.add_tag("symbol", id, tag)

    return json.dumps({"ok": True, "name": sym["name"],
                       "tags_added": len(tags.split(",")) if tags else 0})


@mcp.tool()
def code_magic_set_tags(id: str, tags: str, entity_type: str = "symbol") -> str:
    """Set semantic tags on a symbol or file.

    Args:
        id: Symbol ID or file ID
        tags: Comma-separated tags (e.g. "mutates_state,does_io,security_sensitive")
        entity_type: "symbol" or "file"
    """
    store = _get_store()
    tag_list = [t.strip() for t in tags.split(",") if t.strip()]
    for tag in tag_list:
        store.add_tag(entity_type, id, tag)
    return json.dumps({"ok": True, "tags_added": len(tag_list)})


@mcp.tool()
def code_magic_undescribed(entity_type: str = "symbol", limit: int = 20) -> str:
    """List symbols or files that still need descriptions.

    Args:
        entity_type: "symbol" or "file"
        limit: Max results to return
    """
    store = _get_store()
    items = store.undescribed(entity_type, limit)

    if entity_type == "file":
        return json.dumps({
            "entity_type": "file",
            "count": len(items),
            "items": [
                {"id": item["id"], "path": item["relative_path"],
                 "project": item["project_name"]}
                for item in items
            ]
        }, indent=2)
    else:
        return json.dumps({
            "entity_type": "symbol",
            "count": len(items),
            "items": [
                {"id": item["id"], "name": item["name"], "kind": item["kind"],
                 "file": item["relative_path"],
                 "lines": f"{item['line_start']}-{item['line_end']}",
                 "project": item["project_name"]}
                for item in items
            ]
        }, indent=2)


def _format_context(ctx: dict) -> dict:
    """Format a context dict for MCP output."""
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
            "lines": f"{sym['line_start']}-{sym['line_end']}",
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


def _get_file_path(store: CodeMagicStore, file_id: str) -> str:
    f = store.get_file(file_id)
    return f["relative_path"] if f else ""


def main():
    parser = argparse.ArgumentParser(description="code-magic MCP server")
    parser.add_argument("--db", type=str, default=None,
                        help="Path to SQLite database")
    args = parser.parse_args()

    if args.db:
        os.environ["CODE_MAGIC_DB"] = args.db

    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()

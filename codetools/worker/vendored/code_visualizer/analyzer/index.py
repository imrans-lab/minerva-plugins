"""
code-magic indexer CLI.

Usage: python -m analyzer.index <repo_path> [--db <db_path>] [--project <name>]
"""

import argparse
import subprocess
import sys
import time
from pathlib import Path
from datetime import datetime, timezone

from .store import CodeMagicStore, make_signature_hash
from .extract import parse_file, extract_symbols, walk_repo
from .edges import detect_edges


def get_git_hash(file_path: Path) -> str:
    """Content hash of the file's CURRENT bytes (git blob SHA).

    Uses `git hash-object` (NOT `git log -1`) so the stored hash reflects the
    working-tree content. This lets stale_check detect uncommitted edits — not
    just new commits. `git hash-object` works on tracked or untracked content
    and even outside a repo. Empty string if git is unavailable.
    """
    try:
        result = subprocess.run(
            ["git", "hash-object", str(file_path)],
            capture_output=True, text=True, cwd=file_path.parent,
            timeout=5)
        return result.stdout.strip()
    except Exception:
        return ""


def index_repo(repo_path: Path, db_path: Path, project_name: str):
    """Index a repository into the code-magic store."""
    repo_path = repo_path.resolve()

    print(f"Indexing {repo_path} as project '{project_name}'")
    print(f"Store: {db_path}")

    store = CodeMagicStore(str(db_path))
    t0 = time.time()

    # Find all .gd files
    gd_files = walk_repo(repo_path)
    print(f"Found {len(gd_files)} .gd files")

    # Create/update project
    now = datetime.now(timezone.utc).isoformat()
    project_id = store.upsert_project(project_name, str(repo_path),
                                      language="gdscript",
                                      last_indexed_at=now)

    # Phase 1: Parse all files and extract symbols
    print("\n── Phase 1: Extracting symbols ──")
    all_file_symbols = {}  # {relative_path: [symbol_dicts]}
    all_symbols_by_name = {}  # {name: [symbol_dicts]} for edge resolution
    file_id_map = {}  # {relative_path: file_id}
    symbol_id_map = {}  # {(name, file_path, line_start): symbol_id}

    for gd_file in gd_files:
        relative_path = str(gd_file.relative_to(repo_path))
        tree, code = parse_file(gd_file)
        if tree is None:
            continue

        line_count = code.count(b"\n") + 1
        git_hash = get_git_hash(gd_file)

        file_id = store.upsert_file(project_id, relative_path,
                                    git_hash=git_hash, line_count=line_count)
        file_id_map[relative_path] = file_id

        symbols = extract_symbols(tree, code, relative_path)
        print(f"  {relative_path}: {len(symbols)} symbols")

        # Annotate symbols with file info for edge detection
        for sym in symbols:
            sym["_file_path"] = relative_path
            sym["_file_id"] = file_id
            sym["_tree"] = tree
            sym["_code"] = code

        all_file_symbols[relative_path] = symbols

        # Build name index
        for sym in symbols:
            all_symbols_by_name.setdefault(sym["name"], []).append(sym)

    # Write symbols to store
    print("\n── Phase 1b: Writing symbols to store ──")
    total_symbols = 0
    for relative_path, symbols in all_file_symbols.items():
        file_id = file_id_map[relative_path]
        parent_id_map = {}  # {parent_name: symbol_id} for this file

        for sym in symbols:
            parent_sym_id = None
            if sym["parent_name"] and sym["parent_name"] in parent_id_map:
                parent_sym_id = parent_id_map[sym["parent_name"]]

            sid = store.upsert_symbol(
                file_id=file_id,
                name=sym["name"],
                kind=sym["kind"],
                signature=sym["signature"],
                line_start=sym["line_start"],
                line_end=sym["line_end"],
                parent_symbol_id=parent_sym_id,
                is_entry_point=sym["is_entry_point"],
                signature_hash=sym["signature_hash"],
            )

            symbol_id_map[(sym["name"], relative_path, sym["line_start"])] = sid
            if sym["kind"] in ("class",):
                parent_id_map[sym["name"]] = sid

            total_symbols += 1

    print(f"  Total symbols stored: {total_symbols}")

    # Phase 1c: Create class-to-member "contains" edges
    print("\n── Phase 1c: Creating class containment edges ──")
    contains_count = 0
    members = store.conn.execute(
        "SELECT id, parent_symbol_id FROM symbols WHERE parent_symbol_id IS NOT NULL"
    ).fetchall()
    for m in members:
        store.upsert_edge(m["parent_symbol_id"], m["id"], "contains", confidence=1.0)
        contains_count += 1
    print(f"  {contains_count} contains edges (class → member)")

    # Phase 2: Detect edges
    print("\n── Phase 2: Detecting edges ──")
    total_edges = 0

    for relative_path, symbols in all_file_symbols.items():
        tree = symbols[0]["_tree"] if symbols else None
        code = symbols[0]["_code"] if symbols else None
        if tree is None:
            continue

        raw_edges = detect_edges(tree, code, symbols, all_symbols_by_name,
                                 file_id_map)

        for edge in raw_edges:
            source_key = edge["source"]
            target_key = edge["target"]

            source_id = symbol_id_map.get(source_key)
            target_id = symbol_id_map.get(target_key)

            if source_id and target_id:
                store.upsert_edge(source_id, target_id,
                                  edge["edge_type"], edge["confidence"])
                total_edges += 1

    print(f"  Total edges stored: {total_edges}")

    # Update entry points for signal handlers discovered during edge detection
    print("\n── Phase 2b: Updating entry points from signal connections ──")
    entry_updates = 0
    for relative_path, symbols in all_file_symbols.items():
        for sym in symbols:
            if sym.get("is_entry_point") and sym["kind"] == "function":
                key = (sym["name"], relative_path, sym["line_start"])
                sid = symbol_id_map.get(key)
                if sid:
                    existing = store.get_symbol(sid)
                    if existing and not existing["is_entry_point"]:
                        store.conn.execute(
                            "UPDATE symbols SET is_entry_point = 1 WHERE id = ?",
                            (sid,))
                        entry_updates += 1
    if entry_updates:
        store.conn.commit()
        print(f"  Updated {entry_updates} signal handlers as entry points")

    # Tag MCP tool classes
    _tag_mcp_tools(store, project_id, all_file_symbols, symbol_id_map)

    # Mark all test file symbols as entry points
    _tag_test_entries(store, all_file_symbols, symbol_id_map)

    # Final stats
    elapsed = time.time() - t0
    stats = store.stats()
    print(f"\n── Done in {elapsed:.1f}s ──")
    print(f"  Projects: {stats['projects']}")
    print(f"  Files: {stats['files']}")
    print(f"  Symbols: {stats['symbols']}")
    print(f"  Edges: {stats['edges']}")
    print(f"  Described: {stats['described_symbols']} symbols, {stats['described_files']} files")

    store.close()


def _tag_mcp_tools(store, project_id, all_file_symbols, symbol_id_map):
    """Mark classes in scripts/tools/ as entry points (dispatched by name)."""
    updates = 0
    for relative_path, symbols in all_file_symbols.items():
        if "tools/" in relative_path or "mcp/" in relative_path:
            for sym in symbols:
                if sym["kind"] == "class":
                    key = (sym["name"], relative_path, sym["line_start"])
                    sid = symbol_id_map.get(key)
                    if sid:
                        store.conn.execute(
                            "UPDATE symbols SET is_entry_point = 1 WHERE id = ?",
                            (sid,))
                        store.add_tag("symbol", sid, "mcp-tool")
                        updates += 1
    if updates:
        store.conn.commit()
        print(f"  Tagged {updates} MCP tool classes as entry points")


def _tag_test_entries(store, all_file_symbols, symbol_id_map):
    """Mark all symbols in test files as entry points."""
    updates = 0
    for relative_path, symbols in all_file_symbols.items():
        if relative_path.startswith("test/"):
            for sym in symbols:
                key = (sym["name"], relative_path, sym["line_start"])
                sid = symbol_id_map.get(key)
                if sid:
                    store.conn.execute(
                        "UPDATE symbols SET is_entry_point = 1 WHERE id = ?",
                        (sid,))
                    updates += 1
    if updates:
        store.conn.commit()
        print(f"  Tagged {updates} test symbols as entry points")


def main():
    parser = argparse.ArgumentParser(description="Index a GDScript repo into code-magic")
    parser.add_argument("repo_path", type=Path, help="Path to the repo to index")
    parser.add_argument("--db", type=Path,
                        default=Path(__file__).parent.parent / "data" / "code-magic.db",
                        help="Path to SQLite database")
    parser.add_argument("--project", type=str, default=None,
                        help="Project name (defaults to repo directory name)")
    args = parser.parse_args()

    if not args.repo_path.is_dir():
        print(f"Error: {args.repo_path} is not a directory")
        sys.exit(1)

    project_name = args.project or args.repo_path.resolve().name
    index_repo(args.repo_path, args.db, project_name)


if __name__ == "__main__":
    main()

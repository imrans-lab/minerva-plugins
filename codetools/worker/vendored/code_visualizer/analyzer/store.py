"""
code-magic SQLite store.

Schema: projects, files, symbols, edges, tags with FTS5 on descriptions.
All IDs are text (qualified names or UUIDs) for cross-repo extensibility.
"""

import sqlite3
import hashlib
import os
from pathlib import Path
from typing import Optional


SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS projects (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    path TEXT NOT NULL,
    language TEXT NOT NULL DEFAULT '',
    description TEXT NOT NULL DEFAULT '',
    last_indexed_at TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS files (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL REFERENCES projects(id),
    relative_path TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    last_analyzed_git_hash TEXT NOT NULL DEFAULT '',
    line_count INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS symbols (
    id TEXT PRIMARY KEY,
    file_id TEXT NOT NULL REFERENCES files(id),
    name TEXT NOT NULL,
    kind TEXT NOT NULL,  -- function, class, signal, enum, variable, constant
    signature TEXT NOT NULL DEFAULT '',
    line_start INTEGER NOT NULL DEFAULT 0,
    line_end INTEGER NOT NULL DEFAULT 0,
    description TEXT NOT NULL DEFAULT '',
    parent_symbol_id TEXT DEFAULT NULL REFERENCES symbols(id),
    is_entry_point INTEGER NOT NULL DEFAULT 0,
    signature_hash TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS edges (
    id TEXT PRIMARY KEY,
    source_symbol_id TEXT NOT NULL REFERENCES symbols(id),
    target_symbol_id TEXT NOT NULL REFERENCES symbols(id),
    edge_type TEXT NOT NULL,  -- calls, connects, imports, inherits, preloads
    confidence REAL NOT NULL DEFAULT 1.0
);

CREATE TABLE IF NOT EXISTS tags (
    id TEXT PRIMARY KEY,
    entity_type TEXT NOT NULL,  -- project, file, symbol
    entity_id TEXT NOT NULL,
    tag_name TEXT NOT NULL,
    tag_value TEXT NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_files_project ON files(project_id);
CREATE INDEX IF NOT EXISTS idx_symbols_file ON symbols(file_id);
CREATE INDEX IF NOT EXISTS idx_symbols_kind ON symbols(kind);
CREATE INDEX IF NOT EXISTS idx_symbols_name ON symbols(name);
CREATE INDEX IF NOT EXISTS idx_symbols_signature_hash ON symbols(signature_hash);
CREATE INDEX IF NOT EXISTS idx_symbols_entry_point ON symbols(is_entry_point);
CREATE INDEX IF NOT EXISTS idx_edges_source ON edges(source_symbol_id);
CREATE INDEX IF NOT EXISTS idx_edges_target ON edges(target_symbol_id);
CREATE INDEX IF NOT EXISTS idx_edges_type ON edges(edge_type);
CREATE INDEX IF NOT EXISTS idx_tags_entity ON tags(entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_tags_name ON tags(tag_name);

CREATE VIRTUAL TABLE IF NOT EXISTS descriptions_fts USING fts5(
    entity_id,
    entity_type,
    name,
    description,
    content='',
    tokenize='porter'
);
"""


def _make_id(*parts: str) -> str:
    """Generate a deterministic ID from parts (e.g., project+file+symbol)."""
    raw = "::".join(parts)
    return hashlib.sha256(raw.encode()).hexdigest()[:16]


def _signature_hash(param_count: int, param_types: list[str], return_type: str) -> str:
    """Normalized hash for DRY candidate detection."""
    normalized = f"{param_count}:{','.join(sorted(param_types))}:{return_type}"
    return hashlib.md5(normalized.encode()).hexdigest()[:12]


class CodeMagicStore:
    """SQLite-backed code knowledge store."""

    def __init__(self, db_path: str):
        self.db_path = db_path
        self.conn = sqlite3.connect(db_path)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.execute("PRAGMA foreign_keys=ON")
        self._init_schema()

    def _init_schema(self):
        self.conn.executescript(SCHEMA_SQL)
        self.conn.commit()

    def close(self):
        self.conn.close()

    # ── Write path ──

    def upsert_project(self, name: str, path: str, language: str = "",
                       description: str = "", last_indexed_at: str = "") -> str:
        pid = _make_id("project", name)
        self.conn.execute(
            """INSERT INTO projects (id, name, path, language, description, last_indexed_at)
               VALUES (?, ?, ?, ?, ?, ?)
               ON CONFLICT(id) DO UPDATE SET
                 path=excluded.path, language=excluded.language,
                 description=excluded.description, last_indexed_at=excluded.last_indexed_at""",
            (pid, name, path, language, description, last_indexed_at))
        self.conn.commit()
        return pid

    def upsert_file(self, project_id: str, relative_path: str,
                    git_hash: str = "", line_count: int = 0,
                    description: str = "") -> str:
        fid = _make_id("file", project_id, relative_path)
        self.conn.execute(
            """INSERT INTO files (id, project_id, relative_path, description,
                                  last_analyzed_git_hash, line_count)
               VALUES (?, ?, ?, ?, ?, ?)
               ON CONFLICT(id) DO UPDATE SET
                 description=excluded.description,
                 last_analyzed_git_hash=excluded.last_analyzed_git_hash,
                 line_count=excluded.line_count""",
            (fid, project_id, relative_path, description, git_hash, line_count))
        self.conn.commit()
        return fid

    def upsert_symbol(self, file_id: str, name: str, kind: str,
                      signature: str = "", line_start: int = 0,
                      line_end: int = 0, description: str = "",
                      parent_symbol_id: Optional[str] = None,
                      is_entry_point: bool = False,
                      signature_hash: str = "") -> str:
        sid = _make_id("symbol", file_id, name, kind, str(line_start))
        self.conn.execute(
            """INSERT INTO symbols (id, file_id, name, kind, signature, line_start,
                                    line_end, description, parent_symbol_id,
                                    is_entry_point, signature_hash)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT(id) DO UPDATE SET
                 signature=excluded.signature, line_start=excluded.line_start,
                 line_end=excluded.line_end, description=excluded.description,
                 parent_symbol_id=excluded.parent_symbol_id,
                 is_entry_point=excluded.is_entry_point,
                 signature_hash=excluded.signature_hash""",
            (sid, file_id, name, kind, signature, line_start, line_end,
             description, parent_symbol_id, int(is_entry_point), signature_hash))
        self.conn.commit()
        return sid

    def upsert_edge(self, source_id: str, target_id: str,
                    edge_type: str, confidence: float = 1.0) -> str:
        eid = _make_id("edge", source_id, target_id, edge_type)
        self.conn.execute(
            """INSERT INTO edges (id, source_symbol_id, target_symbol_id,
                                  edge_type, confidence)
               VALUES (?, ?, ?, ?, ?)
               ON CONFLICT(id) DO UPDATE SET confidence=excluded.confidence""",
            (eid, source_id, target_id, edge_type, confidence))
        self.conn.commit()
        return eid

    def add_tag(self, entity_type: str, entity_id: str,
                tag_name: str, tag_value: str = "") -> str:
        tid = _make_id("tag", entity_type, entity_id, tag_name)
        self.conn.execute(
            """INSERT INTO tags (id, entity_type, entity_id, tag_name, tag_value)
               VALUES (?, ?, ?, ?, ?)
               ON CONFLICT(id) DO UPDATE SET tag_value=excluded.tag_value""",
            (tid, entity_type, entity_id, tag_name, tag_value))
        self.conn.commit()
        return tid

    def rebuild_fts(self):
        """Rebuild the FTS index from current symbols and files."""
        self.conn.execute("DROP TABLE IF EXISTS descriptions_fts")
        self.conn.execute("""CREATE VIRTUAL TABLE descriptions_fts USING fts5(
            entity_id, entity_type, name, description,
            content='', tokenize='porter'
        )""")
        self.conn.execute(
            """INSERT INTO descriptions_fts (entity_id, entity_type, name, description)
               SELECT id, 'symbol', name, description FROM symbols WHERE description != ''""")
        self.conn.execute(
            """INSERT INTO descriptions_fts (entity_id, entity_type, name, description)
               SELECT id, 'file', relative_path, description FROM files WHERE description != ''""")
        self.conn.commit()

    def set_description(self, entity_type: str, entity_id: str, description: str):
        """Set description on a symbol or file, and update FTS."""
        if entity_type == "symbol":
            self.conn.execute(
                "UPDATE symbols SET description = ? WHERE id = ?",
                (description, entity_id))
        elif entity_type == "file":
            self.conn.execute(
                "UPDATE files SET description = ? WHERE id = ?",
                (description, entity_id))
        self.conn.commit()
        self.rebuild_fts()

    def clear_project(self, project_id: str):
        """Remove all data for a project (for re-indexing)."""
        file_ids = [r["id"] for r in self.conn.execute(
            "SELECT id FROM files WHERE project_id = ?", (project_id,))]
        if file_ids:
            placeholders = ",".join("?" * len(file_ids))
            sym_ids = [r["id"] for r in self.conn.execute(
                f"SELECT id FROM symbols WHERE file_id IN ({placeholders})", file_ids)]
            if sym_ids:
                sp = ",".join("?" * len(sym_ids))
                self.conn.execute(
                    f"DELETE FROM edges WHERE source_symbol_id IN ({sp}) OR target_symbol_id IN ({sp})",
                    sym_ids + sym_ids)
                self.conn.execute(
                    f"DELETE FROM tags WHERE entity_type='symbol' AND entity_id IN ({sp})", sym_ids)
                self.conn.execute(
                    f"DELETE FROM symbols WHERE id IN ({sp})", sym_ids)
            self.conn.execute(
                f"DELETE FROM tags WHERE entity_type='file' AND entity_id IN ({placeholders})", file_ids)
            self.conn.execute(
                f"DELETE FROM files WHERE id IN ({placeholders})", file_ids)
        self.conn.execute(
            "DELETE FROM tags WHERE entity_type='project' AND entity_id = ?", (project_id,))
        self.conn.commit()

    # ── Read / Query path ──

    def search(self, query: str, limit: int = 20) -> list[dict]:
        """Full-text search across descriptions."""
        rows = self.conn.execute(
            """SELECT entity_id, entity_type, name, description,
                      rank
               FROM descriptions_fts
               WHERE descriptions_fts MATCH ?
               ORDER BY rank
               LIMIT ?""",
            (query, limit)).fetchall()
        return [dict(r) for r in rows]

    def get_symbol(self, symbol_id: str) -> Optional[dict]:
        row = self.conn.execute(
            "SELECT * FROM symbols WHERE id = ?", (symbol_id,)).fetchone()
        return dict(row) if row else None

    def get_symbol_by_name(self, name: str, project_id: Optional[str] = None) -> list[dict]:
        """Find symbols by name, optionally scoped to a project."""
        if project_id:
            rows = self.conn.execute(
                """SELECT s.* FROM symbols s
                   JOIN files f ON s.file_id = f.id
                   WHERE s.name = ? AND f.project_id = ?""",
                (name, project_id)).fetchall()
        else:
            rows = self.conn.execute(
                "SELECT * FROM symbols WHERE name = ?", (name,)).fetchall()
        return [dict(r) for r in rows]

    def get_file(self, file_id: str) -> Optional[dict]:
        row = self.conn.execute(
            "SELECT * FROM files WHERE id = ?", (file_id,)).fetchone()
        return dict(row) if row else None

    def get_file_by_path(self, relative_path: str, project_id: Optional[str] = None) -> Optional[dict]:
        if project_id:
            row = self.conn.execute(
                "SELECT * FROM files WHERE relative_path = ? AND project_id = ?",
                (relative_path, project_id)).fetchone()
        else:
            row = self.conn.execute(
                "SELECT * FROM files WHERE relative_path = ?",
                (relative_path,)).fetchone()
        return dict(row) if row else None

    def get_symbols_in_file(self, file_id: str) -> list[dict]:
        rows = self.conn.execute(
            "SELECT * FROM symbols WHERE file_id = ? ORDER BY line_start",
            (file_id,)).fetchall()
        return [dict(r) for r in rows]

    def get_context(self, symbol_id: str) -> dict:
        """Full context for a symbol: details, edges in/out, file info, tags."""
        sym = self.get_symbol(symbol_id)
        if not sym:
            return {"error": f"Symbol {symbol_id} not found"}

        file_info = self.get_file(sym["file_id"])

        incoming = self.conn.execute(
            """SELECT e.edge_type, e.confidence, s.name, s.kind, s.id,
                      f.relative_path
               FROM edges e
               JOIN symbols s ON e.source_symbol_id = s.id
               JOIN files f ON s.file_id = f.id
               WHERE e.target_symbol_id = ?""",
            (symbol_id,)).fetchall()

        outgoing = self.conn.execute(
            """SELECT e.edge_type, e.confidence, s.name, s.kind, s.id,
                      f.relative_path
               FROM edges e
               JOIN symbols s ON e.target_symbol_id = s.id
               JOIN files f ON s.file_id = f.id
               WHERE e.source_symbol_id = ?""",
            (symbol_id,)).fetchall()

        tags = self.conn.execute(
            "SELECT tag_name, tag_value FROM tags WHERE entity_type='symbol' AND entity_id=?",
            (symbol_id,)).fetchall()

        return {
            "symbol": sym,
            "file": dict(file_info) if file_info else None,
            "incoming_edges": [dict(r) for r in incoming],
            "outgoing_edges": [dict(r) for r in outgoing],
            "tags": [dict(r) for r in tags],
        }

    def get_project(self, project_id: str) -> Optional[dict]:
        row = self.conn.execute(
            "SELECT * FROM projects WHERE id = ?", (project_id,)).fetchone()
        return dict(row) if row else None

    def get_project_by_name(self, name: str) -> Optional[dict]:
        row = self.conn.execute(
            "SELECT * FROM projects WHERE name = ?", (name,)).fetchone()
        return dict(row) if row else None

    def list_projects(self) -> list[dict]:
        rows = self.conn.execute("SELECT * FROM projects").fetchall()
        return [dict(r) for r in rows]

    def list_files(self, project_id: str) -> list[dict]:
        rows = self.conn.execute(
            "SELECT * FROM files WHERE project_id = ? ORDER BY relative_path",
            (project_id,)).fetchall()
        return [dict(r) for r in rows]

    # ── Analysis queries ──

    def dead_code_candidates(self, project_id: Optional[str] = None) -> list[dict]:
        """Symbols with zero incoming edges and is_entry_point=false."""
        query = """
            SELECT s.*, f.relative_path
            FROM symbols s
            JOIN files f ON s.file_id = f.id
            WHERE s.is_entry_point = 0
              AND s.kind IN ('function', 'class')
              AND s.id NOT IN (SELECT target_symbol_id FROM edges)
        """
        params = []
        if project_id:
            query += " AND f.project_id = ?"
            params.append(project_id)
        query += " ORDER BY f.relative_path, s.line_start"
        return [dict(r) for r in self.conn.execute(query, params).fetchall()]

    def dry_candidates(self, project_id: Optional[str] = None) -> list[dict]:
        """Groups of symbols sharing the same signature_hash."""
        query = """
            SELECT s.signature_hash, COUNT(*) as count,
                   GROUP_CONCAT(s.name, ', ') as names,
                   GROUP_CONCAT(f.relative_path || ':' || s.line_start, ', ') as locations
            FROM symbols s
            JOIN files f ON s.file_id = f.id
            WHERE s.signature_hash != '' AND s.kind = 'function'
        """
        params = []
        if project_id:
            query += " AND f.project_id = ?"
            params.append(project_id)
        query += " GROUP BY s.signature_hash HAVING COUNT(*) > 1 ORDER BY count DESC"
        return [dict(r) for r in self.conn.execute(query, params).fetchall()]

    def coupling_hotspots(self, project_id: Optional[str] = None,
                          limit: int = 20) -> list[dict]:
        """Symbols ranked by fan-out (most outgoing edges)."""
        query = """
            SELECT s.name, s.kind, f.relative_path, s.id,
                   COUNT(e.id) as fan_out
            FROM symbols s
            JOIN files f ON s.file_id = f.id
            JOIN edges e ON e.source_symbol_id = s.id
        """
        params = []
        if project_id:
            query += " WHERE f.project_id = ?"
            params.append(project_id)
        query += " GROUP BY s.id ORDER BY fan_out DESC LIMIT ?"
        params.append(limit)
        return [dict(r) for r in self.conn.execute(query, params).fetchall()]

    def fan_in(self, symbol_id: str) -> int:
        row = self.conn.execute(
            "SELECT COUNT(*) as c FROM edges WHERE target_symbol_id = ?",
            (symbol_id,)).fetchone()
        return row["c"]

    def fan_out(self, symbol_id: str) -> int:
        row = self.conn.execute(
            "SELECT COUNT(*) as c FROM edges WHERE source_symbol_id = ?",
            (symbol_id,)).fetchone()
        return row["c"]

    def undescribed(self, entity_type: str = "symbol",
                    limit: int = 50) -> list[dict]:
        """List symbols or files with empty descriptions."""
        if entity_type == "file":
            rows = self.conn.execute(
                """SELECT f.id, f.relative_path, p.name as project_name
                   FROM files f JOIN projects p ON f.project_id = p.id
                   WHERE f.description = ''
                   ORDER BY f.relative_path LIMIT ?""",
                (limit,)).fetchall()
        else:
            rows = self.conn.execute(
                """SELECT s.id, s.name, s.kind, s.line_start, s.line_end,
                          f.relative_path, p.name as project_name
                   FROM symbols s
                   JOIN files f ON s.file_id = f.id
                   JOIN projects p ON f.project_id = p.id
                   WHERE s.description = ''
                   ORDER BY f.relative_path, s.line_start LIMIT ?""",
                (limit,)).fetchall()
        return [dict(r) for r in rows]

    def stats(self) -> dict:
        """Summary statistics for the store."""
        return {
            "projects": self.conn.execute("SELECT COUNT(*) as c FROM projects").fetchone()["c"],
            "files": self.conn.execute("SELECT COUNT(*) as c FROM files").fetchone()["c"],
            "symbols": self.conn.execute("SELECT COUNT(*) as c FROM symbols").fetchone()["c"],
            "edges": self.conn.execute("SELECT COUNT(*) as c FROM edges").fetchone()["c"],
            "described_symbols": self.conn.execute(
                "SELECT COUNT(*) as c FROM symbols WHERE description != ''").fetchone()["c"],
            "described_files": self.conn.execute(
                "SELECT COUNT(*) as c FROM files WHERE description != ''").fetchone()["c"],
        }


# Convenience: module-level helpers
def make_signature_hash(param_count: int, param_types: list[str],
                        return_type: str) -> str:
    return _signature_hash(param_count, param_types, return_type)


def make_id(*parts: str) -> str:
    return _make_id(*parts)

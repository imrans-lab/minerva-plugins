"""
code-magic symbol extractor.

Walks a repo, parses .gd files with tree-sitter-gdscript, extracts symbols.
"""

import tree_sitter_gdscript as tsg
from tree_sitter import Language, Parser
from pathlib import Path
from typing import Optional

from .store import make_signature_hash

# Godot lifecycle methods that are called by the engine, not user code
GODOT_LIFECYCLE_METHODS = {
    "_ready", "_process", "_physics_process", "_notification",
    "_init", "_enter_tree", "_exit_tree", "_input", "_unhandled_input",
    "_unhandled_key_input", "_gui_input", "_draw", "_get_configuration_warnings",
    "_get_minimum_size", "_shortcut_input",
}

_lang = Language(tsg.language())
_parser = Parser(_lang)


def parse_file(file_path: Path) -> Optional["tree_sitter.Tree"]:
    """Parse a .gd file and return the tree-sitter tree."""
    try:
        code = file_path.read_bytes()
        return _parser.parse(code), code
    except Exception as e:
        print(f"  [WARN] Failed to parse {file_path}: {e}")
        return None, None


def extract_symbols(tree, code: bytes, relative_path: str) -> list[dict]:
    """Extract all symbols from a parsed tree.

    Returns a list of symbol dicts with:
      name, kind, signature, line_start, line_end, parent_name,
      is_entry_point, signature_hash, params, return_type, docstring
    """
    symbols = []
    root = tree.root_node

    # Extract top-level info
    class_name = _extract_class_name(root)
    extends = _extract_extends(root)

    # Add class-level symbol if class_name is declared
    if class_name:
        sig = f"class_name {class_name}"
        if extends:
            sig += f" extends {extends}"
        symbols.append({
            "name": class_name,
            "kind": "class",
            "signature": sig,
            "line_start": 1,
            "line_end": code.count(b"\n") + 1,
            "parent_name": None,
            "is_entry_point": False,
            "signature_hash": "",
            "params": [],
            "return_type": extends or "",
            "docstring": "",
        })

    # Walk top-level children
    for node in root.children:
        _extract_node(node, symbols, class_name, code)

    return symbols


def _extract_node(node, symbols: list, parent_name: Optional[str], code: bytes):
    """Extract symbols from a single AST node."""
    ntype = node.type

    if ntype == "function_definition":
        _extract_function(node, symbols, parent_name, code)
    elif ntype == "class_definition":
        _extract_inner_class(node, symbols, parent_name, code)
    elif ntype == "signal_statement":
        _extract_signal(node, symbols, parent_name)
    elif ntype == "enum_definition":
        _extract_enum(node, symbols, parent_name)
    elif ntype in ("variable_statement", "export_variable_statement",
                    "onready_variable_statement"):
        _extract_variable(node, symbols, parent_name, ntype)
    elif ntype == "const_statement":
        _extract_const(node, symbols, parent_name)


def _extract_function(node, symbols: list, parent_name: Optional[str],
                      code: bytes):
    """Extract a function definition."""
    name_node = node.child_by_field_name("name")
    if not name_node:
        return

    name = name_node.text.decode()
    is_static = any(c.type == "static_keyword" for c in node.children)
    params = _extract_params(node)
    return_type = _extract_return_type(node)
    docstring = _extract_docstring(node, code)

    param_types = [p.get("type", "") for p in params]
    sig_hash = make_signature_hash(len(params), param_types, return_type)

    param_str = ", ".join(
        f"{p['name']}: {p['type']}" if p.get("type") else p["name"]
        for p in params
    )
    sig = f"{'static ' if is_static else ''}func {name}({param_str})"
    if return_type:
        sig += f" -> {return_type}"

    is_entry = name in GODOT_LIFECYCLE_METHODS

    symbols.append({
        "name": name,
        "kind": "function",
        "signature": sig,
        "line_start": node.start_point[0] + 1,
        "line_end": node.end_point[0] + 1,
        "parent_name": parent_name,
        "is_entry_point": is_entry,
        "signature_hash": sig_hash,
        "params": params,
        "return_type": return_type,
        "docstring": docstring,
    })


def _extract_inner_class(node, symbols: list, parent_name: Optional[str],
                         code: bytes):
    """Extract an inner class and its members."""
    name_node = node.child_by_field_name("name")
    if not name_node:
        return

    name = name_node.text.decode()
    extends = ""
    for child in node.children:
        if child.type == "extends_statement":
            type_node = child.child_by_field_name("type") or _first_named(child)
            if type_node:
                extends = type_node.text.decode()

    sig = f"class {name}"
    if extends:
        sig += f" extends {extends}"

    symbols.append({
        "name": name,
        "kind": "class",
        "signature": sig,
        "line_start": node.start_point[0] + 1,
        "line_end": node.end_point[0] + 1,
        "parent_name": parent_name,
        "is_entry_point": False,
        "signature_hash": "",
        "params": [],
        "return_type": extends,
        "docstring": "",
    })

    # Extract members of the inner class
    body = node.child_by_field_name("body")
    if body:
        for child in body.children:
            _extract_node(child, symbols, name, code)


def _extract_signal(node, symbols: list, parent_name: Optional[str]):
    """Extract a signal declaration."""
    name_node = None
    for child in node.children:
        if child.type == "name":
            name_node = child
            break

    if not name_node:
        return

    name = name_node.text.decode()
    params = _extract_params(node)

    param_str = ", ".join(
        f"{p['name']}: {p['type']}" if p.get("type") else p["name"]
        for p in params
    )
    sig = f"signal {name}({param_str})" if params else f"signal {name}"

    symbols.append({
        "name": name,
        "kind": "signal",
        "signature": sig,
        "line_start": node.start_point[0] + 1,
        "line_end": node.end_point[0] + 1,
        "parent_name": parent_name,
        "is_entry_point": False,
        "signature_hash": "",
        "params": params,
        "return_type": "",
        "docstring": "",
    })


def _extract_enum(node, symbols: list, parent_name: Optional[str]):
    """Extract an enum definition."""
    name_node = node.child_by_field_name("name")
    name = name_node.text.decode() if name_node else "(anonymous_enum)"

    symbols.append({
        "name": name,
        "kind": "enum",
        "signature": f"enum {name}" if name_node else "enum",
        "line_start": node.start_point[0] + 1,
        "line_end": node.end_point[0] + 1,
        "parent_name": parent_name,
        "is_entry_point": False,
        "signature_hash": "",
        "params": [],
        "return_type": "",
        "docstring": "",
    })


def _extract_variable(node, symbols: list, parent_name: Optional[str],
                      node_type: str):
    """Extract a variable declaration."""
    name_node = node.child_by_field_name("name")
    if not name_node:
        return

    name = name_node.text.decode()
    var_type = _extract_var_type(node)

    prefix = "var"
    kind = "variable"
    if node_type == "export_variable_statement":
        prefix = "@export var"
    elif node_type == "onready_variable_statement":
        prefix = "@onready var"

    sig = f"{prefix} {name}"
    if var_type:
        sig += f": {var_type}"

    symbols.append({
        "name": name,
        "kind": kind,
        "signature": sig,
        "line_start": node.start_point[0] + 1,
        "line_end": node.end_point[0] + 1,
        "parent_name": parent_name,
        "is_entry_point": False,
        "signature_hash": "",
        "params": [],
        "return_type": var_type,
        "docstring": "",
    })


def _extract_const(node, symbols: list, parent_name: Optional[str]):
    """Extract a const declaration."""
    name_node = node.child_by_field_name("name")
    if not name_node:
        return

    name = name_node.text.decode()
    var_type = _extract_var_type(node)

    sig = f"const {name}"
    if var_type:
        sig += f": {var_type}"

    symbols.append({
        "name": name,
        "kind": "constant",
        "signature": sig,
        "line_start": node.start_point[0] + 1,
        "line_end": node.end_point[0] + 1,
        "parent_name": parent_name,
        "is_entry_point": False,
        "signature_hash": "",
        "params": [],
        "return_type": var_type,
        "docstring": "",
    })


# ── Helpers ──

def _extract_class_name(root) -> Optional[str]:
    for child in root.children:
        if child.type == "class_name_statement":
            name_node = child.child_by_field_name("name")
            if name_node:
                return name_node.text.decode()
    return None


def _extract_extends(root) -> Optional[str]:
    for child in root.children:
        if child.type == "extends_statement":
            # Try field name first, then first named child
            type_node = child.child_by_field_name("type") or _first_named(child)
            if type_node:
                return type_node.text.decode()
    return None


def _extract_params(node) -> list[dict]:
    """Extract parameters from a function or signal node."""
    params = []
    for child in node.children:
        if child.type == "parameters":
            for param in child.named_children:
                if param.type in ("typed_parameter", "typed_default_parameter"):
                    p_name = ""
                    p_type = ""
                    for pc in param.children:
                        if pc.type == "identifier":
                            p_name = pc.text.decode()
                        elif pc.type == "type":
                            p_type = pc.text.decode()
                    params.append({"name": p_name, "type": p_type})
                elif param.type == "default_parameter":
                    p_name = ""
                    for pc in param.children:
                        if pc.type == "identifier":
                            p_name = pc.text.decode()
                            break
                    params.append({"name": p_name, "type": ""})
                elif param.type == "identifier":
                    params.append({"name": param.text.decode(), "type": ""})
            break
    return params


def _extract_return_type(node) -> str:
    """Extract return type from a function definition."""
    # The return type is a direct child 'type' node after the parameters
    found_params = False
    for child in node.children:
        if child.type == "parameters":
            found_params = True
        elif found_params and child.type == "type":
            return child.text.decode()
        elif child.type == "body":
            break
    return ""


def _extract_var_type(node) -> str:
    """Extract type from a variable/const statement."""
    for child in node.children:
        if child.type == "type":
            return child.text.decode()
    return ""


def _extract_docstring(node, code: bytes) -> str:
    """Extract ## comments above a function as its docstring."""
    lines = code.decode(errors="replace").split("\n")
    func_line = node.start_point[0]  # 0-indexed

    doc_lines = []
    i = func_line - 1
    while i >= 0:
        line = lines[i].strip()
        if line.startswith("##"):
            doc_lines.insert(0, line[2:].strip())
            i -= 1
        else:
            break

    return "\n".join(doc_lines) if doc_lines else ""


def _first_named(node):
    """Return first named child of a node."""
    for child in node.children:
        if child.is_named:
            return child
    return None


def walk_repo(repo_path: Path) -> list[Path]:
    """Find all .gd files in a repo, excluding addons and vendor dirs."""
    gd_files = []
    for gd_file in sorted(repo_path.rglob("*.gd")):
        rel = gd_file.relative_to(repo_path)
        parts = rel.parts
        # Skip common vendor/addon directories
        if any(p in ("addons", "vendor", ".godot", ".git") for p in parts):
            continue
        gd_files.append(gd_file)
    return gd_files

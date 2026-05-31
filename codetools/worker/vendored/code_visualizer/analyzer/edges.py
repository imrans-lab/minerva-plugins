"""
code-magic edge detector.

Detects relationships between symbols: function calls, signal connections,
preload/load references, and inheritance.
"""

import re
from pathlib import Path
from typing import Optional


def detect_edges(tree, code: bytes, file_symbols: list[dict],
                 all_symbols: dict[str, list[dict]],
                 file_map: dict[str, str]) -> list[dict]:
    """Detect edges from symbols in this file to any known symbol.

    Args:
        tree: parsed tree-sitter tree
        code: raw file bytes
        file_symbols: symbols extracted from this file
        all_symbols: {name: [symbol_dicts]} across all files
        file_map: {relative_path: file_id} for resolving preloads

    Returns:
        list of edge dicts: {source, target, edge_type, confidence}
        where source/target are (name, file_relative_path, line_start) tuples
        that the caller resolves to symbol IDs.
    """
    edges = []
    root = tree.root_node

    # Build a set of function symbols in this file for quick lookup
    func_symbols = [s for s in file_symbols if s["kind"] == "function"]

    for func_sym in func_symbols:
        # Find the function's AST node by line number
        func_node = _find_node_at_line(root, func_sym["line_start"] - 1)
        if not func_node:
            continue

        body = func_node.child_by_field_name("body")
        if not body:
            continue

        # Detect calls within this function body
        _detect_calls(body, func_sym, all_symbols, edges)

        # Detect signal connections
        _detect_signal_connects(body, func_sym, all_symbols, edges)

        # Detect signal emits
        _detect_signal_emits(body, func_sym, all_symbols, edges)

        # Detect .new() constructor calls (instancing)
        _detect_instances(body, func_sym, all_symbols, edges)

        # Detect static method calls (ClassName.method())
        _detect_static_calls(body, func_sym, all_symbols, edges)

    # Detect top-level .new() calls (e.g., in variable initializers)
    _detect_instances(root, file_symbols[0] if file_symbols else None,
                      all_symbols, edges, top_level=True)

    # Detect top-level static calls (e.g., in const initializers)
    _detect_static_calls(root, file_symbols[0] if file_symbols else None,
                         all_symbols, edges)

    # Detect preload/load at file level
    _detect_preloads(root, file_symbols, file_map, edges)

    # Detect inheritance edges
    _detect_inheritance(root, file_symbols, all_symbols, edges)

    return edges


def _detect_calls(node, caller: dict, all_symbols: dict[str, list[dict]],
                  edges: list):
    """Recursively find call expressions and create edges."""
    for child in node.children:
        if child.type == "call":
            callee_name = _get_call_name(child)
            if callee_name and callee_name in all_symbols:
                # Don't self-link
                targets = all_symbols[callee_name]
                for target in targets:
                    if (target["name"] == caller["name"] and
                            target.get("_file_path") == caller.get("_file_path") and
                            target["line_start"] == caller["line_start"]):
                        continue
                    confidence = 0.8 if len(targets) == 1 else 0.5
                    edges.append({
                        "source": _sym_key(caller),
                        "target": _sym_key(target),
                        "edge_type": "calls",
                        "confidence": confidence,
                    })

        elif child.type == "attribute":
            # method call: obj.method(args)
            call_node = None
            for ac in child.children:
                if ac.type == "attribute_call":
                    call_node = ac
                    break

            if call_node:
                method_name = None
                for cc in call_node.children:
                    if cc.type == "identifier":
                        method_name = cc.text.decode()
                        break

                if method_name and method_name in all_symbols:
                    targets = all_symbols[method_name]
                    for target in targets:
                        if (target["name"] == caller["name"] and
                                target.get("_file_path") == caller.get("_file_path") and
                                target["line_start"] == caller["line_start"]):
                            continue
                        # Method calls on objects are lower confidence
                        confidence = 0.6 if len(targets) == 1 else 0.3
                        edges.append({
                            "source": _sym_key(caller),
                            "target": _sym_key(target),
                            "edge_type": "calls",
                            "confidence": confidence,
                        })

        # Recurse into child nodes
        if child.named_child_count > 0:
            _detect_calls(child, caller, all_symbols, edges)


def _detect_signal_connects(node, caller: dict,
                            all_symbols: dict[str, list[dict]],
                            edges: list):
    """Detect signal.connect(handler) patterns.

    Handles three forms:
      1. signal_name.connect(handler_func)
      2. signal_name.connect(Callable(self, "handler_func"))
      3. signal_name.connect(func(...): ...)  — inline lambda
    """
    code_text = node.text.decode(errors="replace")

    # Pattern 1 & 2: named handler or Callable
    connect_named = re.compile(
        r'(\w+)\.connect\(\s*(?:Callable\([^,]+,\s*["\'](\w+)["\']\)|(\w+))\s*\)')

    for match in connect_named.finditer(code_text):
        signal_name = match.group(1)
        handler_name = match.group(2) or match.group(3)

        if not handler_name:
            continue

        if signal_name in all_symbols:
            signal_targets = [s for s in all_symbols[signal_name]
                              if s["kind"] == "signal"]
            handler_targets = all_symbols.get(handler_name, [])

            for sig in signal_targets:
                for handler in handler_targets:
                    edges.append({
                        "source": _sym_key(sig),
                        "target": _sym_key(handler),
                        "edge_type": "connects",
                        "confidence": 0.9,
                    })

            # Mark handler as entry point
            for handler in handler_targets:
                handler["is_entry_point"] = True

    # Pattern 3: lambda/inline connect — signal.connect(func(...): ...)
    # We can't name the handler, so connect signal → the function containing the .connect()
    connect_lambda = re.compile(
        r'(\w+)\.connect\(\s*func\s*\(')

    for match in connect_lambda.finditer(code_text):
        signal_name = match.group(1)

        if signal_name in all_symbols:
            signal_targets = [s for s in all_symbols[signal_name]
                              if s["kind"] == "signal"]

            for sig in signal_targets:
                # Edge from signal → the function that sets up the connection
                edges.append({
                    "source": _sym_key(sig),
                    "target": _sym_key(caller),
                    "edge_type": "connects",
                    "confidence": 0.7,
                })


def _detect_signal_emits(node, caller: dict,
                         all_symbols: dict[str, list[dict]],
                         edges: list):
    """Detect signal.emit() patterns.

    Creates an edge from the emitting function to the signal.
    Handles: signal_name.emit(...) and obj.signal_name.emit(...)
    """
    code_text = node.text.decode(errors="replace")

    # Pattern: signal_name.emit(  or  .signal_name.emit(
    emit_pattern = re.compile(r'(?:^|[.\s])(\w+)\.emit\s*\(', re.MULTILINE)

    for match in emit_pattern.finditer(code_text):
        signal_name = match.group(1)

        if signal_name in all_symbols:
            signal_targets = [s for s in all_symbols[signal_name]
                              if s["kind"] == "signal"]

            for sig in signal_targets:
                edges.append({
                    "source": _sym_key(caller),
                    "target": _sym_key(sig),
                    "edge_type": "emits",
                    "confidence": 0.85,
                })


def _detect_instances(node, caller: dict, all_symbols: dict[str, list[dict]],
                      edges: list, top_level: bool = False):
    """Detect ClassName.new() constructor calls and create 'instances' edges."""
    if not caller or not node:
        return

    code_text = node.text.decode(errors="replace")

    # Pattern: ClassName.new(...) — capital letter start distinguishes class names
    instance_pattern = re.compile(r'([A-Z]\w+)\.new\s*\(')

    for match in instance_pattern.finditer(code_text):
        class_name = match.group(1)
        if class_name in all_symbols:
            class_targets = [s for s in all_symbols[class_name]
                             if s["kind"] == "class"]
            for target in class_targets:
                edges.append({
                    "source": _sym_key(caller),
                    "target": _sym_key(target),
                    "edge_type": "instances",
                    "confidence": 0.9,
                })


def _detect_static_calls(node, caller: dict, all_symbols: dict[str, list[dict]],
                         edges: list):
    """Detect ClassName.method() static calls.

    Creates a 'calls' edge from caller to the method, AND a 'static_call' edge
    from caller to the class itself (so the class gets an incoming edge).
    Skips .new() (handled by _detect_instances) and .emit()/.connect() (handled elsewhere).
    """
    if not caller or not node:
        return

    code_text = node.text.decode(errors="replace")

    # Pattern: ClassName.method_name(  — capital letter start for class name
    static_call_pattern = re.compile(r'([A-Z]\w+)\.(\w+)\s*\(')

    # Track what we've already added to avoid duplicates within this node
    seen = set()

    for match in static_call_pattern.finditer(code_text):
        class_name = match.group(1)
        method_name = match.group(2)

        # Skip patterns handled by other detectors
        if method_name in ('new', 'emit', 'connect', 'disconnect'):
            continue

        # Skip Godot builtins (Time, OS, Engine, etc.)
        if class_name in ('Time', 'OS', 'Engine', 'Input', 'ProjectSettings',
                          'ResourceLoader', 'ClassDB', 'JSON', 'Marshalls',
                          'FileAccess', 'DirAccess', 'IP', 'Geometry2D',
                          'Geometry3D', 'DisplayServer', 'RenderingServer',
                          'PhysicsServer2D', 'PhysicsServer3D', 'EditorInterface',
                          'String', 'Array', 'Dictionary', 'PackedByteArray',
                          'Color', 'Vector2', 'Vector3', 'Callable', 'Error'):
            continue

        key = (class_name, method_name)
        if key in seen:
            continue
        seen.add(key)

        if class_name in all_symbols:
            # Edge to the class itself
            class_targets = [s for s in all_symbols[class_name]
                             if s["kind"] == "class"]
            for target in class_targets:
                # Don't self-link
                if (_sym_key(caller) == _sym_key(target)):
                    continue
                edges.append({
                    "source": _sym_key(caller),
                    "target": _sym_key(target),
                    "edge_type": "calls",
                    "confidence": 0.85,
                })


def _detect_preloads(root, file_symbols: list[dict],
                     file_map: dict[str, str], edges: list):
    """Detect preload() and load() calls at file level."""
    code_text = root.text.decode(errors="replace")

    preload_pattern = re.compile(r'(?:preload|load)\(\s*["\']res://([^"\']+)["\']\s*\)')

    for match in preload_pattern.finditer(code_text):
        ref_path = match.group(1)
        if ref_path in file_map:
            # Create a file-level dependency edge
            # Use the first symbol in the file as source (usually the class)
            if file_symbols:
                edges.append({
                    "source": _sym_key(file_symbols[0]),
                    "target": ("__file__", ref_path, 0),
                    "edge_type": "preloads",
                    "confidence": 1.0,
                })


def _detect_inheritance(root, file_symbols: list[dict],
                        all_symbols: dict[str, list[dict]],
                        edges: list):
    """Detect extends relationships."""
    for child in root.children:
        if child.type == "extends_statement":
            type_node = child.child_by_field_name("type")
            if not type_node:
                for c in child.children:
                    if c.is_named:
                        type_node = c
                        break

            if type_node:
                base_name = type_node.text.decode()
                # Find class symbols in this file
                class_syms = [s for s in file_symbols if s["kind"] == "class"]
                base_targets = [s for s in all_symbols.get(base_name, [])
                                if s["kind"] == "class"]

                for cls in class_syms:
                    for base in base_targets:
                        edges.append({
                            "source": _sym_key(cls),
                            "target": _sym_key(base),
                            "edge_type": "inherits",
                            "confidence": 1.0,
                        })


def _get_call_name(call_node) -> Optional[str]:
    """Extract the function name from a call node."""
    for child in call_node.children:
        if child.type == "identifier":
            return child.text.decode()
    return None


def _find_node_at_line(root, line: int):
    """Find the function_definition node starting at the given line."""
    for child in root.children:
        if child.type == "function_definition" and child.start_point[0] == line:
            return child
    return None


def _sym_key(sym: dict) -> tuple:
    """Create a lookup key for a symbol."""
    return (sym["name"], sym.get("_file_path", ""), sym["line_start"])

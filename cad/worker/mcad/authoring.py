"""Conservative source spans for editing a single explicitly placed occurrence."""
from . import ast_nodes as ast
from .assembly import Instance
from .reference import MeshReference
from .lexer import tokenize, TT
from .parser import parse


def placements(source, document, model):
    statements = parse(source).statements
    tokens = tokenize(source)
    lines = source.splitlines(keepends=True)
    offsets, offset = [], 0
    for line in lines:
        offsets.append(offset)
        offset += len(line)
    rows = {}
    counts = {}
    for statement in statements:
        if isinstance(statement, ast.Assignment):
            counts[statement.name] = counts.get(statement.name, 0) + 1
    for statement in statements:
        if not isinstance(statement, ast.Assignment) or counts[statement.name] != 1:
            continue
        value = document.bindings.get(statement.name)
        if not isinstance(value, (Instance, MeshReference)):
            continue
        expr = statement.value
        while isinstance(expr, ast.FuncCall) and expr.name in ('translate', 'rotate', 'scale') and len(expr.args) == 2:
            expr = expr.args[1]
        if not isinstance(expr, ast.FuncCall) or expr.name not in ('instance', 'mesh'):
            continue
        # Literal occurrence identity only: a function, loop, alias or computed
        # identity cannot be edited as though it were one independent placement.
        if isinstance(value, Instance):
            identity = expr.kwargs.get('id')
            if not isinstance(identity, ast.String) or identity.value != value.id:
                continue
            object_id, matrix = value.id, [list(r) for r in value.matrix]
        else:
            object_id, matrix = statement.name, value.to_dict()['matrix']
        candidates = [i for i in model.get('instances', []) if i['id'] == object_id]
        if model.get('instances') and not candidates:
            continue
        if any(i['id'].endswith('/' + object_id) for i in model.get('instances', [])):
            continue
        if candidates and (len(candidates) != 1 or candidates[0]['matrix'] != matrix):
            continue
        start_index = next((i for i,t in enumerate(tokens) if t.line == statement.line and t.type == TT.EQ), None)
        if start_index is None:
            continue
        expression_tokens = []
        depth = 0
        for token in tokens[start_index + 1:]:
            if token.type in (TT.NEWLINE, TT.EOF) and depth == 0:
                break
            if token.type in (TT.LPAREN, TT.LBRACKET): depth += 1
            if token.type in (TT.RPAREN, TT.RBRACKET): depth -= 1
            expression_tokens.append(token)
        if not expression_tokens:
            continue
        first, last = expression_tokens[0], expression_tokens[-1]
        start = offsets[first.line-1] + first.col
        end = offsets[last.line-1] + last.col + len(str(last.value))
        rows.setdefault(object_id, []).append({'binding': statement.name,
            'start': start, 'end': end, 'expression': source[start:end], 'matrix': matrix,
            'source_line': statement.line})
    return {name: values[0] for name, values in rows.items() if len(values) == 1}

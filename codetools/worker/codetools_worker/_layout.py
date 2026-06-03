"""Force-directed layout (ported from code-magic/viz/compute_layout.py @9cc9403).

Pure stdlib only (json / math / random) — no third-party deps.
Implements D3 forceManyBody + forceLink model.

Public API:
    compute_layout(data, seed_positions=None, seed_data=None,
                   width=1200, height=800, iterations=500) -> data

Mutates each node dict in-place, adding float `x` and `y` keys.
Returns the same `data` dict so callers can chain.
"""

from __future__ import annotations

import math
import random

# Fixed seed so layouts are deterministic across runs.
_RNG = random.Random(42)


def compute_layout(
    data: dict,
    seed_positions: dict | None = None,
    seed_data: dict | None = None,
    width: float = 1200,
    height: float = 800,
    iterations: int = 500,
) -> dict:
    """Run force-directed layout matching D3's forceManyBody + forceLink model.

    Args:
        data:           graph dict with 'nodes' and 'edges' lists.
        seed_positions: {node_id: [x, y]} for existing layout. When given,
                        only new/moved nodes are free to move.
        seed_data:      original graph data dict used to detect file moves.
        width:          canvas width (pixels).
        height:         canvas height (pixels).
        iterations:     simulation steps (500 ≈ D3 default α-decay to 0.001).

    Mutates each node in data['nodes'] with `x` and `y` float keys.
    Returns `data`.
    """
    nodes = data["nodes"]
    edges = data["edges"]

    # ── Initialise positions ────────────────────────────────────────────────
    positions: dict[str, list[float]] = {}
    for node in nodes:
        nid = node["id"]
        if seed_positions and nid in seed_positions:
            positions[nid] = list(seed_positions[nid])
        else:
            if seed_positions:
                # New node — place near connected neighbours that already have
                # seed positions, or near centre.
                neighbours: list[list[float]] = []
                for e in edges:
                    if e["source"] == nid and e["target"] in positions:
                        neighbours.append(positions[e["target"]])
                    elif e["target"] == nid and e["source"] in positions:
                        neighbours.append(positions[e["source"]])
                if neighbours:
                    avg_x = sum(p[0] for p in neighbours) / len(neighbours)
                    avg_y = sum(p[1] for p in neighbours) / len(neighbours)
                    positions[nid] = [
                        avg_x + _RNG.uniform(-30, 30),
                        avg_y + _RNG.uniform(-30, 30),
                    ]
                else:
                    positions[nid] = [
                        width / 2 + _RNG.uniform(-200, 200),
                        height / 2 + _RNG.uniform(-200, 200),
                    ]
            else:
                spread = math.sqrt(len(nodes)) * 30
                positions[nid] = [
                    width / 2 + _RNG.uniform(-spread, spread),
                    height / 2 + _RNG.uniform(-spread, spread),
                ]

    velocities: dict[str, list[float]] = {nid: [0.0, 0.0] for nid in positions}

    # ── Which nodes are free to move vs pinned ──────────────────────────────
    free_nodes: set[str] = set()
    if seed_positions:
        seed_files: dict[str, str] = {}
        if seed_data:
            for n in seed_data.get("nodes", []):
                seed_files[n["id"]] = n.get("file", "")
        for node in nodes:
            nid = node["id"]
            if nid not in seed_positions:
                free_nodes.add(nid)
            elif node.get("file", "") != seed_files.get(nid, ""):
                free_nodes.add(nid)
    else:
        free_nodes = set(positions.keys())

    # ── Layout constants ────────────────────────────────────────────────────
    charge_strength = -1500.0
    link_distance: dict[str, float] = {
        "contains": 50,
        "instances": 100,
        "default": 80,
    }
    link_strength: dict[str, float] = {
        "contains": 0.15,
        "instances": 0.1,
        "default": 0.08,
    }
    center_gravity = 0.005
    velocity_decay = 0.6
    alpha = 1.0
    alpha_decay = 1 - math.pow(0.001, 1.0 / iterations)

    node_ids = [n["id"] for n in nodes]

    # ── Simulation loop ─────────────────────────────────────────────────────
    for _step in range(iterations):
        # Charge (repulsion) — brute force; fine for < ~200 nodes.
        for i, ni in enumerate(node_ids):
            px, py = positions[ni]
            fx, fy = 0.0, 0.0
            for j, nj in enumerate(node_ids):
                if i == j:
                    continue
                qx, qy = positions[nj]
                dx, dy = px - qx, py - qy
                dist_sq = dx * dx + dy * dy
                if dist_sq < 1.0:
                    dx, dy = _RNG.uniform(-1, 1), _RNG.uniform(-1, 1)
                    dist_sq = dx * dx + dy * dy
                    if dist_sq < 0.01:
                        continue
                dist = math.sqrt(dist_sq)
                if dist > 400:
                    continue
                force = charge_strength / dist
                fx += dx / dist * force
                fy += dy / dist * force
            velocities[ni][0] += fx
            velocities[ni][1] += fy

        # Links (springs with rest length).
        for edge in edges:
            sid, tid = edge["source"], edge["target"]
            if sid not in positions or tid not in positions:
                continue
            sx, sy = positions[sid]
            tx, ty = positions[tid]
            dx, dy = tx - sx, ty - sy
            dist = math.sqrt(dx * dx + dy * dy)
            if dist < 0.1:
                continue
            etype = edge.get("type", "default")
            rest = link_distance.get(etype, link_distance["default"])
            strength = link_strength.get(etype, link_strength["default"])
            displacement = (dist - rest) / dist
            fx = dx * displacement * strength * alpha
            fy = dy * displacement * strength * alpha
            velocities[sid][0] += fx
            velocities[sid][1] += fy
            velocities[tid][0] -= fx
            velocities[tid][1] -= fy

        # Center gravity.
        for nid in node_ids:
            px, py = positions[nid]
            velocities[nid][0] += (width / 2 - px) * center_gravity * alpha
            velocities[nid][1] += (height / 2 - py) * center_gravity * alpha

        # Apply velocities (clamp + decay).
        for nid in node_ids:
            vx, vy = velocities[nid]
            vx *= velocity_decay
            vy *= velocity_decay
            speed = math.sqrt(vx * vx + vy * vy)
            if speed > 50:
                vx, vy = vx / speed * 50, vy / speed * 50
            velocities[nid] = [vx, vy]
            if nid in free_nodes:
                positions[nid][0] += vx
                positions[nid][1] += vy

        alpha *= 1 - alpha_decay

    # ── Write positions back into nodes ─────────────────────────────────────
    for node in nodes:
        pos = positions[node["id"]]
        node["x"] = round(pos[0], 1)
        node["y"] = round(pos[1], 1)

    return data

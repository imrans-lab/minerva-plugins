"""
agent-router: Standalone PCB routing tool for KiCad

A Python-based PCB routing tool designed for **human-AI collaborative design**.
Supports single-layer and multi-layer routing with collision detection and
visualization.

Philosophy: This tool treats routing friction as design feedback. Use
design_review() before routing to identify opportunities for pin swaps,
component repositioning, or layout changes.
"""

__version__ = "0.1.0"

from .board import Board, Pad, Net, Obstacle
from .grid import RoutingGrid, GridCell
from .pathfinder import find_path, Path, PathSegment
from .router import (
    route_board, route_board_with_hints, route_bus,
    design_review, RoutingResult, DesignReview, BusGroup
)
from .kicad_io import read_kicad_pcb, load_kicad_pcb, write_kicad_pcb, TraceSegment, Via
from .visualizer import visualize_ascii, visualize_svg
from .hints import (
    RoutingHints, BusHint, NetHint, Waypoint, AvoidArea, InternalBridge,
    load_hints, save_hints, generate_hints_from_review
)
from .yaml_loader import load_board_with_hints

__all__ = [
    # Board model
    "Board",
    "Pad",
    "Net",
    "Obstacle",
    # Grid
    "RoutingGrid",
    "GridCell",
    # Pathfinding
    "find_path",
    "Path",
    "PathSegment",
    # Router
    "route_board",
    "route_board_with_hints",
    "route_bus",
    "design_review",
    "RoutingResult",
    "DesignReview",
    "BusGroup",
    # KiCad I/O
    "read_kicad_pcb",
    "load_kicad_pcb",
    "write_kicad_pcb",
    "TraceSegment",
    "Via",
    # Visualization
    "visualize_ascii",
    "visualize_svg",
    # Hints
    "RoutingHints",
    "BusHint",
    "NetHint",
    "Waypoint",
    "AvoidArea",
    "InternalBridge",
    "load_hints",
    "save_hints",
    "generate_hints_from_review",
    # YAML loader
    "load_board_with_hints",
]

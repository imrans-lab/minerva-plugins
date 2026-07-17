"""
KiCad PCB file I/O.

Reads and writes KiCad PCB files (.kicad_pcb), parsing footprints,
pads, nets, and writing trace segments and vias.
"""

from dataclasses import dataclass, field
from typing import Optional, Any
from pathlib import Path as FilePath
import re
import math


@dataclass
class TraceSegment:
    """A trace segment in KiCad format."""
    start: tuple[float, float]
    end: tuple[float, float]
    width: float
    layer: str
    net: int  # Net number

    def to_kicad(self) -> str:
        """Convert to KiCad s-expression format."""
        return (
            f'(segment (start {self.start[0]} {self.start[1]}) '
            f'(end {self.end[0]} {self.end[1]}) '
            f'(width {self.width}) (layer "{self.layer}") (net {self.net}))'
        )


@dataclass
class Via:
    """A via in KiCad format."""
    position: tuple[float, float]
    size: float
    drill: float
    net: int  # Net number
    layers: tuple[str, str] = ("F.Cu", "B.Cu")

    def to_kicad(self) -> str:
        """Convert to KiCad s-expression format."""
        return (
            f'(via (at {self.position[0]} {self.position[1]}) '
            f'(size {self.size}) (drill {self.drill}) '
            f'(layers "{self.layers[0]}" "{self.layers[1]}") (net {self.net}))'
        )

    @classmethod
    def from_canonical(cls, via: dict, net_number: int = 0) -> "Via":
        """Build a Via from a canonical via dict (x_mm/y_mm/diameter_mm/
        drill_mm/from_layer/to_layer — see pcb/ui/model/pcb_data.gd and
        pcb/docs/board-yaml.md). Maps the canonical top/bottom layer span to
        KiCad F.Cu/B.Cu at THIS boundary (the KiCad/engine side of the
        convention).

        ``_CANON_TO_KICAD_LAYER`` intentionally mirrors
        pcb_worker/route_bridge.py's ``_LAYER_MAP`` value-for-value rather
        than importing it: agent_router is a standalone package pcb_worker
        depends ON (never the reverse — see route_bridge.py's module
        docstring), so this 2-entry map can't cross that boundary without
        inverting it. When the source via has no from_layer/to_layer (legacy
        vias), the dataclass default (F.Cu/B.Cu) is kept.
        """
        x = float(via.get("x_mm", 0.0) or 0.0)
        y = float(via.get("y_mm", 0.0) or 0.0)
        size = float(via.get("diameter_mm") or 0.8)
        drill = float(via.get("drill_mm") or 0.4)
        from_layer = via.get("from_layer")
        to_layer = via.get("to_layer")
        if from_layer and to_layer:
            return cls(
                position=(x, y), size=size, drill=drill, net=net_number,
                layers=(_CANON_TO_KICAD_LAYER.get(str(from_layer), "F.Cu"),
                        _CANON_TO_KICAD_LAYER.get(str(to_layer), "B.Cu")),
            )
        return cls(position=(x, y), size=size, drill=drill, net=net_number)


# Canonical top/bottom -> KiCad copper layer name, at the KiCad-export
# boundary. See Via.from_canonical for why this duplicates (rather than
# imports) pcb_worker/route_bridge.py's _LAYER_MAP.
_CANON_TO_KICAD_LAYER = {"top": "F.Cu", "bottom": "B.Cu"}


@dataclass
class KiCadPCB:
    """Parsed KiCad PCB file."""
    footprints: list[dict] = field(default_factory=list)
    nets: dict[str, int] = field(default_factory=dict)  # name -> number
    net_numbers: dict[int, str] = field(default_factory=dict)  # number -> name
    segments: list[TraceSegment] = field(default_factory=list)
    vias: list[Via] = field(default_factory=list)
    raw_content: str = ""
    board_outline: Optional[list[tuple[float, float]]] = None
    width: float = 0.0
    height: float = 0.0

    def add_segment(self, segment: TraceSegment) -> None:
        """Add a trace segment."""
        self.segments.append(segment)

    def add_via(self, via: Via) -> None:
        """Add a via."""
        self.vias.append(via)

    def get_net_number(self, net_name: str) -> int:
        """Get the net number for a net name."""
        return self.nets.get(net_name, 0)


def read_kicad_pcb(pcb_file: str | FilePath) -> "Board":
    """
    Read a KiCad PCB file and return a Board.

    Args:
        pcb_file: Path to .kicad_pcb file

    Returns:
        Board instance with pads, nets, and obstacles
    """
    from .board import Board, Pad, Net, Obstacle

    path = FilePath(pcb_file)
    content = path.read_text()

    board = Board()
    kicad = KiCadPCB(raw_content=content)

    # Parse nets
    net_pattern = r'\(net\s+(\d+)\s+"([^"]*)"\)'
    for match in re.finditer(net_pattern, content):
        net_num = int(match.group(1))
        net_name = match.group(2)
        kicad.nets[net_name] = net_num
        kicad.net_numbers[net_num] = net_name
        board.nets[net_name] = Net(name=net_name, number=net_num)

    # Parse board outline (gr_rect or gr_poly on Edge.Cuts)
    board.width, board.height, origin_x, origin_y = _parse_board_outline(content)
    board.origin = (origin_x, origin_y)

    # Parse footprints and their pads
    footprints = _parse_footprints(content)
    kicad.footprints = footprints

    for fp in footprints:
        fp_ref = fp.get("reference", "")
        fp_pos = fp.get("position", (0, 0))
        fp_rotation = fp.get("rotation", 0)

        for pad_data in fp.get("pads", []):
            pad_num = pad_data.get("number", "")
            pad_net_num = pad_data.get("net", 0)
            pad_net_name = kicad.net_numbers.get(pad_net_num, None)

            # Calculate absolute position with rotation
            rel_x, rel_y = pad_data.get("position", (0, 0))
            abs_x, abs_y = _transform_position(
                rel_x, rel_y, fp_pos[0], fp_pos[1], fp_rotation
            )

            pad = Pad(
                component=fp_ref,
                number=pad_num,
                net=pad_net_name,
                position=(abs_x, abs_y),
                size=pad_data.get("size", (1.0, 1.0)),
                shape=pad_data.get("shape", "rect"),
                pad_type=pad_data.get("type", "smd"),
                drill=pad_data.get("drill"),
                layer=pad_data.get("layer", "F.Cu"),
                rotation=fp_rotation + pad_data.get("rotation", 0)
            )
            board.pads.append(pad)

            # Add to net
            if pad_net_name and pad_net_name in board.nets:
                board.nets[pad_net_name].pads.append(pad)

    # Parse obstacles (mounting holes, keepouts)
    board.obstacles = _parse_obstacles(content)

    board.width = board.width or 100.0
    board.height = board.height or 100.0

    return board


def _parse_board_outline(content: str) -> tuple[float, float, float, float]:
    """Parse board outline and return (width, height, origin_x, origin_y)."""
    # Try to find gr_rect on Edge.Cuts
    rect_pattern = r'\(gr_rect\s+\(start\s+([\d.-]+)\s+([\d.-]+)\)\s+\(end\s+([\d.-]+)\s+([\d.-]+)\).*?\(layer\s+"Edge\.Cuts"\)'
    match = re.search(rect_pattern, content, re.DOTALL)
    if match:
        x1, y1 = float(match.group(1)), float(match.group(2))
        x2, y2 = float(match.group(3)), float(match.group(4))
        origin_x = min(x1, x2)
        origin_y = min(y1, y2)
        return (abs(x2 - x1), abs(y2 - y1), origin_x, origin_y)

    # Try to find multiple gr_line on Edge.Cuts and compute bounding box
    # Updated pattern to handle (stroke ...) before (layer ...)
    line_pattern = r'\(gr_line\s+\(start\s+([\d.-]+)\s+([\d.-]+)\)\s+\(end\s+([\d.-]+)\s+([\d.-]+)\).*?\(layer\s+"Edge\.Cuts"\)'
    points = []
    for match in re.finditer(line_pattern, content, re.DOTALL):
        points.append((float(match.group(1)), float(match.group(2))))
        points.append((float(match.group(3)), float(match.group(4))))

    if points:
        xs = [p[0] for p in points]
        ys = [p[1] for p in points]
        origin_x = min(xs)
        origin_y = min(ys)
        return (max(xs) - min(xs), max(ys) - min(ys), origin_x, origin_y)

    return (100.0, 100.0, 0.0, 0.0)  # Default


def _parse_footprints(content: str) -> list[dict]:
    """Parse footprints from KiCad PCB content."""
    footprints = []

    # Find all footprint blocks - match balanced parentheses
    fp_starts = []
    for match in re.finditer(r'\(footprint\s+"', content):
        fp_starts.append(match.start())

    for start in fp_starts:
        # Find the matching closing paren
        depth = 0
        end = start
        for i in range(start, len(content)):
            if content[i] == '(':
                depth += 1
            elif content[i] == ')':
                depth -= 1
                if depth == 0:
                    end = i + 1
                    break

        fp_content = content[start:end]
        fp = _parse_single_footprint(fp_content)
        if fp:
            footprints.append(fp)

    return footprints


def _parse_single_footprint(fp_content: str) -> Optional[dict]:
    """Parse a single footprint block."""
    fp = {"pads": []}

    # Get footprint name
    name_match = re.search(r'\(footprint\s+"([^"]+)"', fp_content)
    if name_match:
        fp["name"] = name_match.group(1)

    # Get position and rotation
    at_match = re.search(r'\(at\s+([\d.-]+)\s+([\d.-]+)(?:\s+([\d.-]+))?\)', fp_content)
    if at_match:
        fp["position"] = (float(at_match.group(1)), float(at_match.group(2)))
        fp["rotation"] = float(at_match.group(3)) if at_match.group(3) else 0.0

    # Get reference designator
    ref_match = re.search(r'\(fp_text\s+reference\s+"([^"]+)"', fp_content)
    if ref_match:
        fp["reference"] = ref_match.group(1)
    else:
        # Try property reference
        ref_match = re.search(r'\(property\s+"Reference"\s+"([^"]+)"', fp_content)
        if ref_match:
            fp["reference"] = ref_match.group(1)

    # Parse pads
    pad_pattern = r'\(pad\s+"?([^"\s]+)"?\s+(\w+)\s+(\w+)'
    for pad_match in re.finditer(pad_pattern, fp_content):
        pad_start = pad_match.start()
        # Find end of this pad block
        depth = 0
        pad_end = pad_start
        for i in range(pad_start, len(fp_content)):
            if fp_content[i] == '(':
                depth += 1
            elif fp_content[i] == ')':
                depth -= 1
                if depth == 0:
                    pad_end = i + 1
                    break

        pad_content = fp_content[pad_start:pad_end]
        pad = _parse_pad(pad_content)
        if pad:
            fp["pads"].append(pad)

    return fp if fp.get("reference") else None


def _parse_pad(pad_content: str) -> Optional[dict]:
    """Parse a single pad."""
    pad = {}

    # Get pad number, type, shape
    main_match = re.search(r'\(pad\s+"?([^"\s]+)"?\s+(\w+)\s+(\w+)', pad_content)
    if main_match:
        pad["number"] = main_match.group(1)
        pad["type"] = main_match.group(2)  # smd, thru_hole, etc.
        pad["shape"] = main_match.group(3)  # rect, circle, etc.

    # Get position
    at_match = re.search(r'\(at\s+([\d.-]+)\s+([\d.-]+)(?:\s+([\d.-]+))?\)', pad_content)
    if at_match:
        pad["position"] = (float(at_match.group(1)), float(at_match.group(2)))
        pad["rotation"] = float(at_match.group(3)) if at_match.group(3) else 0.0

    # Get size
    size_match = re.search(r'\(size\s+([\d.-]+)\s+([\d.-]+)\)', pad_content)
    if size_match:
        pad["size"] = (float(size_match.group(1)), float(size_match.group(2)))

    # Get drill (for through-hole)
    drill_match = re.search(r'\(drill\s+([\d.-]+)', pad_content)
    if drill_match:
        pad["drill"] = float(drill_match.group(1))

    # Get net
    net_match = re.search(r'\(net\s+(\d+)', pad_content)
    if net_match:
        pad["net"] = int(net_match.group(1))

    # Get layers
    layers_match = re.search(r'\(layers\s+"([^"]+)"', pad_content)
    if layers_match:
        pad["layer"] = layers_match.group(1)

    return pad if pad.get("number") else None


def _transform_position(
    rel_x: float,
    rel_y: float,
    fp_x: float,
    fp_y: float,
    rotation: float
) -> tuple[float, float]:
    """Transform relative pad position to absolute with rotation."""
    # Convert rotation to radians (KiCad uses clockwise rotation in screen coords)
    rad = math.radians(-rotation)

    # Rotate relative position
    rot_x = rel_x * math.cos(rad) - rel_y * math.sin(rad)
    rot_y = rel_x * math.sin(rad) + rel_y * math.cos(rad)

    # Add footprint position
    abs_x = fp_x + rot_x
    abs_y = fp_y + rot_y

    return (abs_x, abs_y)


def _parse_obstacles(content: str) -> list:
    """Parse obstacles (mounting holes, keepouts) from content."""
    from .board import Obstacle

    obstacles = []

    # Find mounting hole footprints by first finding footprint starts with MountingHole
    fp_pattern = r'\(footprint\s+"[^"]*MountingHole[^"]*"'
    for fp_match in re.finditer(fp_pattern, content):
        fp_start = fp_match.start()

        # Find the end of this footprint block (balanced parentheses)
        depth = 0
        fp_end = fp_start
        for i in range(fp_start, len(content)):
            if content[i] == '(':
                depth += 1
            elif content[i] == ')':
                depth -= 1
                if depth == 0:
                    fp_end = i + 1
                    break

        fp_content = content[fp_start:fp_end]

        # Find position (at x y)
        at_match = re.search(r'\(at\s+([\d.-]+)\s+([\d.-]+)', fp_content)
        if not at_match:
            continue

        x, y = float(at_match.group(1)), float(at_match.group(2))

        # Find drill size
        drill_match = re.search(r'\(drill\s+([\d.-]+)', fp_content)
        radius = float(drill_match.group(1)) / 2 if drill_match else 1.5

        obstacles.append(Obstacle(
            position=(x, y),
            type="mounting_hole",
            radius=radius,
            blocks_all_layers=True
        ))

    return obstacles


def load_kicad_pcb(pcb_file: str | FilePath) -> KiCadPCB:
    """
    Load a KiCad PCB file and return the raw KiCadPCB object.

    Use this when you need to modify and write back the PCB file.
    For routing analysis, use read_kicad_pcb() which returns a Board.

    Args:
        pcb_file: Path to .kicad_pcb file

    Returns:
        KiCadPCB instance with raw content and parsed nets
    """
    path = FilePath(pcb_file)
    content = path.read_text()

    kicad = KiCadPCB(raw_content=content)

    # Parse nets
    net_pattern = r'\(net\s+(\d+)\s+"([^"]*)"\)'
    for match in re.finditer(net_pattern, content):
        net_num = int(match.group(1))
        net_name = match.group(2)
        kicad.nets[net_name] = net_num
        kicad.net_numbers[net_num] = net_name

    # Parse board dimensions
    kicad.width, kicad.height, _, _ = _parse_board_outline(content)

    return kicad


def write_kicad_pcb(pcb: KiCadPCB, output_file: str | FilePath) -> None:
    """
    Write routing results back to a KiCad PCB file.

    Preserves original content and adds segments/vias before the closing paren.

    Args:
        pcb: KiCadPCB with segments and vias to add
        output_file: Output file path
    """
    content = pcb.raw_content

    # Find position to insert (before final closing paren)
    insert_pos = content.rfind(')')

    # Build new content to insert
    new_content = "\n"
    for segment in pcb.segments:
        new_content += f"  {segment.to_kicad()}\n"
    for via in pcb.vias:
        new_content += f"  {via.to_kicad()}\n"

    # Insert and write
    final_content = content[:insert_pos] + new_content + content[insert_pos:]

    path = FilePath(output_file)
    path.write_text(final_content)

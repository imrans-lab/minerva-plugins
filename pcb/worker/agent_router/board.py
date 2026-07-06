"""
Board representation for PCB routing.

Contains dataclasses for pads, nets, obstacles, and the main Board class
that loads from KiCad PCB files.
"""

from dataclasses import dataclass, field
from typing import Optional
from pathlib import Path as FilePath


@dataclass
class Pad:
    """Represents a single pad on the board."""
    component: str              # Component reference (e.g., "U1", "R1")
    number: str                 # Pad number (e.g., "1", "A4")
    net: Optional[str]          # Net name (e.g., "VCC", "GND") or None if unconnected
    position: tuple[float, float]  # Absolute position (x, y) in mm
    size: tuple[float, float]      # Size (width, height) in mm
    shape: str = "rect"            # "rect", "circle", "roundrect", "oval"
    pad_type: str = "smd"          # "smd", "thru_hole"
    drill: Optional[float] = None  # Drill diameter for through-hole pads
    layer: str = "F.Cu"            # Primary layer
    rotation: float = 0.0          # Pad rotation in degrees


@dataclass
class Net:
    """Represents a net (electrical connection) on the board."""
    name: str                              # Net name
    number: int                            # Net number in KiCad
    pads: list[Pad] = field(default_factory=list)  # Pads belonging to this net


@dataclass
class Obstacle:
    """Represents a blocked region on the board."""
    position: tuple[float, float]  # Center position (x, y) in mm
    type: str                      # "mounting_hole", "keepout", "via", etc.
    radius: Optional[float] = None  # For circular obstacles
    polygon: Optional[list[tuple[float, float]]] = None  # For polygon obstacles
    blocks_all_layers: bool = True  # Whether it blocks all layers or just one
    layer: Optional[str] = None     # Specific layer if not all


@dataclass
class Board:
    """
    Represents a PCB board for routing.

    Contains all pads, nets, obstacles, and board dimensions.
    Can be loaded from a KiCad PCB file.
    """
    pads: list[Pad] = field(default_factory=list)
    nets: dict[str, Net] = field(default_factory=dict)
    obstacles: list[Obstacle] = field(default_factory=list)
    width: float = 0.0   # Board width in mm
    height: float = 0.0  # Board height in mm
    origin: tuple[float, float] = (0.0, 0.0)  # Board origin

    @classmethod
    def from_kicad(cls, pcb_file: str | FilePath) -> "Board":
        """
        Load a board from a KiCad PCB file.

        Args:
            pcb_file: Path to .kicad_pcb file

        Returns:
            Board instance with pads, nets, and obstacles populated
        """
        from .kicad_io import read_kicad_pcb
        return read_kicad_pcb(str(pcb_file))

    def get_pad(self, component: str, pad_number: str) -> Optional[Pad]:
        """
        Get a specific pad by component reference and pad number.

        Args:
            component: Component reference (e.g., "R1")
            pad_number: Pad number (e.g., "1")

        Returns:
            Pad if found, None otherwise
        """
        for pad in self.pads:
            if pad.component == component and pad.number == pad_number:
                return pad
        return None

    def get_net_pads(self, net_name: str) -> list[Pad]:
        """
        Get all pads belonging to a net.

        Args:
            net_name: Name of the net

        Returns:
            List of pads belonging to the net
        """
        if net_name in self.nets:
            return self.nets[net_name].pads
        return [p for p in self.pads if p.net == net_name]

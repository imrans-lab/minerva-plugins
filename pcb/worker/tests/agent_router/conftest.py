"""
Shared fixtures for agent-router tests.
"""

import pytest
from pathlib import Path

# Get fixtures directory path
FIXTURES_DIR = Path(__file__).parent / "fixtures"


@pytest.fixture
def fixtures_dir():
    """Return the path to the fixtures directory."""
    return FIXTURES_DIR


@pytest.fixture
def two_pads_pcb(fixtures_dir):
    """Path to the two_pads test fixture."""
    return fixtures_dir / "two_pads.kicad_pcb"


@pytest.fixture
def three_resistors_pcb(fixtures_dir):
    """Path to the three_resistors test fixture."""
    return fixtures_dir / "three_resistors.kicad_pcb"


@pytest.fixture
def rotated_component_pcb(fixtures_dir):
    """Path to the rotated_component test fixture."""
    return fixtures_dir / "rotated_component.kicad_pcb"


@pytest.fixture
def board_with_holes_pcb(fixtures_dir):
    """Path to the board_with_holes test fixture."""
    return fixtures_dir / "board_with_holes.kicad_pcb"


@pytest.fixture
def crossing_nets_pcb(fixtures_dir):
    """Path to the crossing_nets test fixture."""
    return fixtures_dir / "crossing_nets.kicad_pcb"


@pytest.fixture
def star_net_pcb(fixtures_dir):
    """Path to the star_net test fixture."""
    return fixtures_dir / "star_net.kicad_pcb"


@pytest.fixture
def tmp_dir(tmp_path):
    """Return a temporary directory for test outputs."""
    return tmp_path

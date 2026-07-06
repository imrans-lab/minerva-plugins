"""pcb_worker — the PCB plugin's Python worker (Go↔Python bridge).

Stateless pure functions over the canonical board-source YAML contract
(pcb/internal/board/board.go, pcb/docs/board-yaml.md). Methods: validate,
generate, gerbers, check_libraries, check_bom, init. See methods.py.
"""

__version__ = "0.1.0"

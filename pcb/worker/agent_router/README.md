# agent-router

A standalone PCB routing tool for KiCad, designed for **human-AI collaborative design**.

## Philosophy: Design Partner, Not Just Router

agent-router is not just an algorithmic routing tool - it's designed to support **collaborative PCB design** between humans and an LLM. This means:

### Routing Friction is Design Feedback

When routing is difficult, don't just "try harder" - ask whether the difficulty reveals a design issue:

- **Are pin assignments fixed?** A button can often use any GPIO. If routing is hard, maybe a different pin makes more sense.
- **Could components move?** Sometimes shifting a component 2mm eliminates crossing traces.
- **Are there functional alternatives?** Two components needing GND might share a trace route.

### The Design Review Workflow

Before routing, review the board for design-level opportunities:

1. **Identify congested areas** - Where do many traces need to cross?
2. **Question constraints** - Which connections are fixed vs. flexible?
3. **Consider alternatives** - Pin swaps, component moves, shared routes
4. **Then route** - With a clear strategy, not just shortest-path algorithms

### Human-AI Collaboration

The tool supports iterative collaboration:

- **Waypoint hints** - Human provides routing guidance via YAML
- **Bus routing** - Group related signals (I2S, SPI, etc.) and route together
- **Design review output** - Tool highlights potential issues before routing
- **Incremental routing** - Route some nets, review, adjust, continue

This philosophy is baked into the tool's structure, not just documentation. When you encounter routing problems, the tool will prompt you to consider design-level changes.

---

## Installation

```bash
cd agent-router
pip install -e ".[dev]"
```

## Command Line Usage

### Route a PCB

```bash
# Basic routing
agent-router route input.kicad_pcb -o output.kicad_pcb

# Single-layer mode (F.Cu only, no vias)
agent-router route input.kicad_pcb -o output.kicad_pcb --single-layer

# Disable vias (try to route on primary layer, fail if impossible)
agent-router route input.kicad_pcb -o output.kicad_pcb --no-vias

# Custom trace width and clearance
agent-router route input.kicad_pcb -o output.kicad_pcb --trace-width 0.3 --clearance 0.25

# Route with longest nets first (sometimes better for dense boards)
agent-router route input.kicad_pcb -o output.kicad_pcb --order longest_first

# JSON output for scripting
agent-router route input.kicad_pcb --json
```

### Extract Pad Information

```bash
# JSON format (default)
agent-router dump-pads board.kicad_pcb --format json

# CSV format
agent-router dump-pads board.kicad_pcb --format csv

# Save to file
agent-router dump-pads board.kicad_pcb -o pads.json
```

### Visualize Board

```bash
# ASCII art (default)
agent-router visualize board.kicad_pcb

# ASCII with custom scale (mm per character)
agent-router visualize board.kicad_pcb --scale 1.0

# SVG output
agent-router visualize board.kicad_pcb --format svg -o board.svg

# Visualize specific layer
agent-router visualize board.kicad_pcb --layer B.Cu
```

## Tips and Tricks

### For Best Routing Results

1. **Start with single-layer mode** for simple boards:
   ```bash
   agent-router route board.kicad_pcb -o routed.kicad_pcb --single-layer
   ```
   If it fails, let it use vias.

2. **Use shorter trace widths** on dense boards to improve routability:
   ```bash
   agent-router route board.kicad_pcb -o routed.kicad_pcb --trace-width 0.2
   ```

3. **Check unrouted nets** in JSON output:
   ```bash
   agent-router route board.kicad_pcb --json | jq '.unrouted'
   ```

4. **Visualize before and after** to verify routing:
   ```bash
   agent-router visualize board.kicad_pcb > before.txt
   agent-router route board.kicad_pcb -o routed.kicad_pcb
   agent-router visualize routed.kicad_pcb > after.txt
   diff before.txt after.txt
   ```

### For AI Integration

1. **Use JSON output** for parsing:
   ```bash
   agent-router dump-pads board.kicad_pcb --format json
   agent-router route board.kicad_pcb --json
   ```

2. **The dump-pads command** gives you everything needed to understand board connectivity:
   - Pad positions and sizes
   - Net groupings (which pads connect)
   - Obstacle locations (mounting holes)
   - Board dimensions

3. **Route incrementally** by processing the output and re-routing if needed.

### Debugging

1. **Test with simple fixtures first**:
   ```bash
   agent-router route fixtures/two_pads.kicad_pcb --json
   ```

2. **Check pad positions** to verify KiCad parsing:
   ```bash
   agent-router dump-pads board.kicad_pcb | jq '.pads[:5]'
   ```

3. **Run tests** to verify installation:
   ```bash
   pytest tests/ -v
   ```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         CLI (cli.py)                        │
│  Commands: route, visualize, dump-pads                      │
└─────────────────────────────────────────────────────────────┘
                              │
          ┌───────────────────┼───────────────────┐
          ▼                   ▼                   ▼
┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
│   Board Model   │  │     Router      │  │   Visualizer    │
│   (board.py)    │  │   (router.py)   │  │ (visualizer.py) │
│                 │  │                 │  │                 │
│ • Pad           │  │ • route_board() │  │ • ASCII output  │
│ • Net           │  │ • Net ordering  │  │ • SVG output    │
│ • Obstacle      │  │ • MST building  │  │                 │
└─────────────────┘  └─────────────────┘  └─────────────────┘
          │                   │
          │                   ▼
          │          ┌─────────────────┐
          │          │   Pathfinder    │
          │          │ (pathfinder.py) │
          │          │                 │
          │          │ • Direct path   │
          │          │ • L-shaped path │
          │          │ • A* algorithm  │
          │          └─────────────────┘
          │                   │
          ▼                   ▼
┌─────────────────┐  ┌─────────────────┐
│   KiCad I/O     │  │  Routing Grid   │
│  (kicad_io.py)  │  │    (grid.py)    │
│                 │  │                 │
│ • Read .kicad_  │  │ • Cell marking  │
│   pcb files     │  │ • Collision     │
│ • Write traces  │  │   detection     │
│ • Write vias    │  │ • Clearance     │
└─────────────────┘  └─────────────────┘
```

## Development Phases

### Phase 1: Project Setup & Board Loading ✅ COMPLETE

**Goal**: Parse KiCad PCB files and extract board information.

**What was implemented**:
- Project structure with pyproject.toml
- `Board`, `Pad`, `Net`, `Obstacle` dataclasses
- KiCad PCB parser for footprints, pads, nets
- Position transform with rotation support
- Test fixtures (6 KiCad PCB files)

**Key files**: `board.py`, `kicad_io.py`

**Tests**: `test_board.py`, `test_kicad_io.py`

---

### Phase 2: Routing Grid ✅ COMPLETE

**Goal**: Create discrete grid for collision detection.

**What was implemented**:
- `RoutingGrid` class with configurable resolution
- Cell marking for pads, obstacles, traces
- Clearance handling around different nets
- Same-net overlap allowed (traces can touch own pads)
- Multi-layer support (F.Cu, B.Cu)

**Key files**: `grid.py`

**Tests**: `test_grid.py`

---

### Phase 3: Basic Pathfinding ✅ COMPLETE

**Goal**: Find paths between pads.

**What was implemented**:
- Direct path (straight line)
- L-shaped path (one bend)
- Path data structures (segments, points)

**Key files**: `pathfinder.py`

**Tests**: `test_pathfinder.py`

---

### Phase 4: A* Pathfinding ✅ COMPLETE

**Goal**: Handle complex routing with multiple bends.

**What was implemented**:
- A* algorithm on grid
- 8-directional movement
- Path simplification (remove unnecessary waypoints)
- Via support for layer changes

**Key files**: `pathfinder.py`

**Tests**: `test_pathfinder.py`

---

### Phase 5: Multi-Net Router ✅ COMPLETE

**Goal**: Route all nets on a board.

**What was implemented**:
- Net ordering (shortest_first, longest_first)
- Minimum spanning tree for multi-pad nets
- Iterative routing with grid updates
- Unrouted net tracking
- Via counting

**Key files**: `router.py`

**Tests**: `test_router.py`

---

### Phase 6: KiCad Output & Visualization ✅ COMPLETE

**Goal**: Write results and visualize.

**What was implemented**:
- Write trace segments in KiCad format
- Write vias in KiCad format
- ASCII board visualization
- SVG board visualization
- Custom pad colors in SVG

**Key files**: `kicad_io.py`, `visualizer.py`

**Tests**: `test_kicad_io.py`, `test_visualizer.py`

---

### Phase 7: CLI & Integration ✅ COMPLETE

**Goal**: Command-line interface.

**What was implemented**:
- `route` command with options
- `visualize` command (ASCII/SVG)
- `dump-pads` command (JSON/CSV)
- JSON output for scripting

**Key files**: `cli.py`

---

### Phase 8: Design Partner Features 🔲 IN PROGRESS

**Goal**: Human-AI collaborative routing.

**Current work**:

1. **Design Review Phase** 🔲
   - Analyze board before routing
   - Detect congested areas and crossing nets
   - Prompt design-level questions (pin flexibility, component placement)
   - Output structured review for human consideration

2. **Bus Routing** 🔲
   - Detect related signals by prefix (I2S_*, SPI_*, etc.)
   - Route as grouped traces with consistent spacing
   - Escape routing from dense components
   - Channel detection for open corridors

3. **Waypoint Hints (YAML)** 🔲
   - User-specified waypoints for traces/buses
   - Preferred directions and avoid areas
   - Explicit bus groupings
   - Integration with routing algorithms

**Future features**:

4. **Design Rule Checking (DRC)**
   - Clearance violations
   - Minimum trace width
   - Annular ring checks
   - Unconnected pads

5. **Route Optimization**
   - Remove unnecessary vias
   - Shorten traces
   - Smooth corners (45° bends)
   - Widen traces where space allows

6. **Differential Pairs**
   - Coupled routing
   - Length matching
   - Impedance control

7. **Ground Planes**
   - Copper pour generation
   - Thermal relief pads
   - Plane splits for mixed signals

---

### Phase 9: pcb-architect Integration 🔲 TODO

**Goal**: Use agent-router from pcb-architect.

**Planned work**:

```python
# In pcb-architect/cli.py
route_parser.add_argument("--use-agent-router", action="store_true")

def cmd_route(args):
    if args.use_agent_router:
        from agent_router import route_board, Board
        board = Board.from_kicad(args.pcb)
        result = route_board(board, single_layer=args.single_layer)
        # Write result...
    else:
        # Existing Freerouting path
        ...
```

---

## Running Tests

```bash
# Run all tests
pytest tests/ -v

# Run specific test file
pytest tests/test_router.py -v

# Run with coverage
pytest tests/ --cov=agent_router --cov-report=html
```

## Current Limitations

1. **No curved traces** - Only straight segments with bends
2. **Simple via model** - Single via type, no blind/buried vias
3. **No impedance control** - Trace width is constant
4. **No length matching** - Nets routed independently
5. **Basic clearance** - Same clearance for all nets
6. **No copper pours** - Traces only, no fills

## Contributing

1. Write tests first (TDD approach)
2. Run `pytest tests/ -v` before committing
3. Keep modules focused and small
4. Document public functions

## License

MIT

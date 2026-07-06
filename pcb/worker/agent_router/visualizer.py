"""
Visualization for PCB routing.

Provides ASCII and SVG visualization of boards, pads, obstacles, and routes.
"""

from typing import Optional

from .board import Board
from .router import Route


def visualize_ascii(
    board: Board,
    routes: Optional[list[Route]] = None,
    scale: float = 2.0,
    layer: str = "F.Cu"
) -> str:
    """
    Generate ASCII art visualization of a board.

    Args:
        board: Board to visualize
        routes: Optional list of routes to display
        scale: mm per character (default 2mm = 1 char)
        layer: Layer to show

    Returns:
        ASCII art string
    """
    # Calculate grid size
    cols = int(board.width / scale) + 2
    rows = int(board.height / scale) + 2

    # Initialize grid with spaces
    grid = [[' ' for _ in range(cols)] for _ in range(rows)]

    # Draw border
    for c in range(cols):
        grid[0][c] = '─'
        grid[rows - 1][c] = '─'
    for r in range(rows):
        grid[r][0] = '│'
        grid[r][cols - 1] = '│'
    grid[0][0] = '┌'
    grid[0][cols - 1] = '┐'
    grid[rows - 1][0] = '└'
    grid[rows - 1][cols - 1] = '┘'

    # Get board origin for coordinate transformation
    origin_x, origin_y = board.origin

    # Draw obstacles (mounting holes)
    for obstacle in board.obstacles:
        c = int((obstacle.position[0] - origin_x) / scale) + 1
        r = int((obstacle.position[1] - origin_y) / scale) + 1
        if 0 < r < rows - 1 and 0 < c < cols - 1:
            grid[r][c] = '○'

    # Draw pads
    for pad in board.pads:
        c = int((pad.position[0] - origin_x) / scale) + 1
        r = int((pad.position[1] - origin_y) / scale) + 1
        if 0 < r < rows - 1 and 0 < c < cols - 1:
            # Use different symbols for different pad types
            if pad.pad_type == "thru_hole":
                grid[r][c] = '◎'
            else:
                grid[r][c] = '●'

    # Draw routes
    if routes:
        for route in routes:
            for path in route.paths:
                for segment in path.segments:
                    _draw_segment(grid, segment, scale, rows, cols, layer, board.origin)

                # Draw vias
                for via_pos in path.vias:
                    c = int((via_pos[0] - origin_x) / scale) + 1
                    r = int((via_pos[1] - origin_y) / scale) + 1
                    if 0 < r < rows - 1 and 0 < c < cols - 1:
                        grid[r][c] = '◉'

    # Convert to string
    lines = [''.join(row) for row in grid]
    return '\n'.join(lines)


def _draw_segment(
    grid: list[list[str]],
    segment,
    scale: float,
    rows: int,
    cols: int,
    target_layer: str,
    origin: tuple[float, float] = (0.0, 0.0)
) -> None:
    """Draw a trace segment on the ASCII grid."""
    if segment.layer != target_layer:
        return

    x1, y1 = segment.start
    x2, y2 = segment.end
    origin_x, origin_y = origin

    c1 = int((x1 - origin_x) / scale) + 1
    r1 = int((y1 - origin_y) / scale) + 1
    c2 = int((x2 - origin_x) / scale) + 1
    r2 = int((y2 - origin_y) / scale) + 1

    # Determine trace character based on direction
    if r1 == r2:  # Horizontal
        char = '─'
    elif c1 == c2:  # Vertical
        char = '│'
    else:  # Diagonal
        char = '╲' if (c2 - c1) * (r2 - r1) > 0 else '╱'

    # Draw using Bresenham's line algorithm
    dc = abs(c2 - c1)
    dr = abs(r2 - r1)
    sc = 1 if c1 < c2 else -1
    sr = 1 if r1 < r2 else -1
    err = dc - dr

    c, r = c1, r1
    while True:
        if 0 < r < rows - 1 and 0 < c < cols - 1:
            if grid[r][c] == ' ':
                grid[r][c] = char

        if c == c2 and r == r2:
            break

        e2 = 2 * err
        if e2 > -dr:
            err -= dr
            c += sc
        if e2 < dc:
            err += dc
            r += sr


def visualize_svg(
    board: Board,
    routes: Optional[list[Route]] = None,
    scale: float = 10.0,
    pad_colors: Optional[dict[str, str]] = None
) -> str:
    """
    Generate SVG visualization of a board.

    Args:
        board: Board to visualize
        routes: Optional list of routes to display
        scale: Pixels per mm
        pad_colors: Optional dict mapping net names to colors

    Returns:
        SVG string
    """
    width = int(board.width * scale) + 40
    height = int(board.height * scale) + 40
    margin = 20  # Border margin

    # Get board origin for coordinate transformation
    origin_x, origin_y = board.origin

    svg_parts = [
        f'<?xml version="1.0" encoding="UTF-8"?>',
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}">',
        f'  <style>',
        f'    .pad {{ fill: #4a90d9; }}',
        f'    .pad-thru {{ fill: none; stroke: #4a90d9; stroke-width: 2; }}',
        f'    .obstacle {{ fill: #888; }}',
        f'    .trace-fcu {{ stroke: #d94a4a; stroke-width: 3; fill: none; }}',
        f'    .trace-bcu {{ stroke: #4ad94a; stroke-width: 3; fill: none; stroke-dasharray: 5,3; }}',
        f'    .via {{ fill: #d9d94a; stroke: #888; }}',
        f'    .board {{ fill: #1a1a2e; stroke: #4a4a6a; stroke-width: 2; }}',
        f'  </style>',
        f'',
        f'  <!-- Board outline -->',
        f'  <rect class="board" x="{margin}" y="{margin}" '
        f'width="{board.width * scale}" height="{board.height * scale}" />',
    ]

    # Draw obstacles (transform from absolute to board-relative coordinates)
    svg_parts.append('  <!-- Obstacles -->')
    for obstacle in board.obstacles:
        x = (obstacle.position[0] - origin_x) * scale + margin
        y = (obstacle.position[1] - origin_y) * scale + margin
        if obstacle.radius:
            r = obstacle.radius * scale
            svg_parts.append(
                f'  <circle class="obstacle" cx="{x:.1f}" cy="{y:.1f}" r="{r:.1f}" />'
            )

    # Draw routes (transform from absolute to board-relative coordinates)
    if routes:
        svg_parts.append('  <!-- Routes -->')
        for route in routes:
            for path in route.paths:
                for segment in path.segments:
                    x1 = (segment.start[0] - origin_x) * scale + margin
                    y1 = (segment.start[1] - origin_y) * scale + margin
                    x2 = (segment.end[0] - origin_x) * scale + margin
                    y2 = (segment.end[1] - origin_y) * scale + margin
                    css_class = "trace-fcu" if segment.layer == "F.Cu" else "trace-bcu"
                    svg_parts.append(
                        f'  <line class="{css_class}" '
                        f'x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" />'
                    )

                # Draw vias
                for via_pos in path.vias:
                    x = (via_pos[0] - origin_x) * scale + margin
                    y = (via_pos[1] - origin_y) * scale + margin
                    svg_parts.append(
                        f'  <circle class="via" cx="{x:.1f}" cy="{y:.1f}" r="4" />'
                    )

    # Draw pads (transform from absolute to board-relative coordinates)
    svg_parts.append('  <!-- Pads -->')
    for pad in board.pads:
        x = (pad.position[0] - origin_x) * scale + margin
        y = (pad.position[1] - origin_y) * scale + margin
        w = pad.size[0] * scale
        h = pad.size[1] * scale

        # Get color from pad_colors if provided
        fill = ""
        if pad_colors and pad.net and pad.net in pad_colors:
            fill = f' style="fill: {pad_colors[pad.net]}"'

        if pad.shape == "circle":
            r = min(w, h) / 2
            if pad.pad_type == "thru_hole":
                svg_parts.append(
                    f'  <circle class="pad-thru" cx="{x:.1f}" cy="{y:.1f}" r="{r:.1f}"{fill} />'
                )
            else:
                svg_parts.append(
                    f'  <circle class="pad" cx="{x:.1f}" cy="{y:.1f}" r="{r:.1f}"{fill} />'
                )
        else:
            # Rectangle (or roundrect)
            rx = x - w / 2
            ry = y - h / 2
            if pad.pad_type == "thru_hole":
                svg_parts.append(
                    f'  <rect class="pad-thru" x="{rx:.1f}" y="{ry:.1f}" '
                    f'width="{w:.1f}" height="{h:.1f}"{fill} />'
                )
            else:
                svg_parts.append(
                    f'  <rect class="pad" x="{rx:.1f}" y="{ry:.1f}" '
                    f'width="{w:.1f}" height="{h:.1f}" rx="1"{fill} />'
                )

    svg_parts.append('</svg>')

    return '\n'.join(svg_parts)

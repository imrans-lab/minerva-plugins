"""
Command-line interface for agent-router.

Provides commands for routing, visualization, and pad extraction.
"""

import argparse
import json
import sys
from pathlib import Path

from .board import Board
from .router import route_board, route_board_with_hints
from .kicad_io import read_kicad_pcb, write_kicad_pcb, KiCadPCB, TraceSegment, Via
from .visualizer import visualize_ascii, visualize_svg
from .yaml_loader import load_board_with_hints


def main():
    """Main CLI entry point."""
    parser = argparse.ArgumentParser(
        prog="agent-router",
        description="Standalone PCB routing tool for KiCad"
    )
    parser.add_argument(
        "--version",
        action="version",
        version="%(prog)s 0.1.0"
    )

    subparsers = parser.add_subparsers(dest="command", help="Available commands")

    # Route command
    route_parser = subparsers.add_parser("route", help="Route a PCB")
    route_parser.add_argument("input", help="Input .kicad_pcb file")
    route_parser.add_argument("-o", "--output", help="Output .kicad_pcb file")
    route_parser.add_argument(
        "--board-yaml",
        help="Board YAML file with routing_hints and internal_nets"
    )
    route_parser.add_argument(
        "--single-layer",
        action="store_true",
        help="Route on single layer only (F.Cu)"
    )
    route_parser.add_argument(
        "--no-vias",
        action="store_true",
        help="Disable vias"
    )
    route_parser.add_argument(
        "--trace-width",
        type=float,
        default=0.25,
        help="Trace width in mm (default: 0.25)"
    )
    route_parser.add_argument(
        "--clearance",
        type=float,
        default=0.2,
        help="Minimum clearance in mm (default: 0.2)"
    )
    route_parser.add_argument(
        "--order",
        choices=["shortest_first", "longest_first", "signals_first"],
        default="shortest_first",
        help="Net ordering strategy (signals_first routes signal nets before power/GND)"
    )
    route_parser.add_argument(
        "--json",
        action="store_true",
        help="Output results as JSON"
    )

    # Visualize command
    viz_parser = subparsers.add_parser("visualize", help="Visualize a PCB")
    viz_parser.add_argument("input", help="Input .kicad_pcb file")
    viz_parser.add_argument(
        "--format",
        choices=["ascii", "svg"],
        default="ascii",
        help="Output format"
    )
    viz_parser.add_argument(
        "-o", "--output",
        help="Output file (default: stdout for ASCII, required for SVG)"
    )
    viz_parser.add_argument(
        "--scale",
        type=float,
        default=2.0,
        help="Scale factor (mm/char for ASCII, px/mm for SVG)"
    )
    viz_parser.add_argument(
        "--layer",
        default="F.Cu",
        help="Layer to visualize (for ASCII)"
    )

    # Dump-pads command
    pads_parser = subparsers.add_parser("dump-pads", help="Extract pad positions")
    pads_parser.add_argument("input", help="Input .kicad_pcb file")
    pads_parser.add_argument(
        "--format",
        choices=["json", "csv"],
        default="json",
        help="Output format"
    )
    pads_parser.add_argument(
        "-o", "--output",
        help="Output file (default: stdout)"
    )

    args = parser.parse_args()

    if args.command == "route":
        cmd_route(args)
    elif args.command == "visualize":
        cmd_visualize(args)
    elif args.command == "dump-pads":
        cmd_dump_pads(args)
    else:
        parser.print_help()
        sys.exit(1)


def cmd_route(args):
    """Execute route command."""
    if args.board_yaml:
        # Load board geometry from KiCad, hints from YAML
        board, hints, internal_nets = load_board_with_hints(
            args.input, args.board_yaml
        )
        result = route_board_with_hints(
            board,
            hints,
            internal_nets=internal_nets,
            allow_vias=not args.no_vias,
            single_layer=args.single_layer,
            order=args.order,
            trace_width=args.trace_width,
            clearance=args.clearance,
        )
    else:
        # Standard mode: load board from KiCad only
        board = Board.from_kicad(args.input)
        result = route_board(
            board,
            allow_vias=not args.no_vias,
            single_layer=args.single_layer,
            order=args.order,
            trace_width=args.trace_width,
            clearance=args.clearance,
        )

    if args.json:
        # Output as JSON
        output = {
            "success": result.success,
            "routes": len(result.routes),
            "via_count": result.via_count,
            "unrouted": [
                {"net": net, "from": f"{p1.component}.{p1.number}", "to": f"{p2.component}.{p2.number}"}
                for net, p1, p2 in result.unrouted
            ]
        }
        print(json.dumps(output, indent=2))
    else:
        # Human-readable output
        print(f"Routing complete: {'SUCCESS' if result.success else 'INCOMPLETE'}")
        print(f"  Routes: {len(result.routes)}")
        print(f"  Vias: {result.via_count}")
        if result.unrouted:
            print(f"  Unrouted: {len(result.unrouted)}")
            for net, p1, p2 in result.unrouted[:5]:  # Show first 5
                print(f"    - {net}: {p1.component}.{p1.number} -> {p2.component}.{p2.number}")
            if len(result.unrouted) > 5:
                print(f"    ... and {len(result.unrouted) - 5} more")

    # Write output if specified
    if args.output and result.routes:
        # Read original PCB
        pcb = KiCadPCB(raw_content=Path(args.input).read_text())

        # Get net number mapping from board
        net_map = {name: net.number for name, net in board.nets.items()}

        # Add segments and vias
        for route in result.routes:
            net_num = net_map.get(route.net, 0)
            for path in route.paths:
                for segment in path.segments:
                    pcb.add_segment(TraceSegment(
                        start=segment.start,
                        end=segment.end,
                        width=args.trace_width,
                        layer=segment.layer,
                        net=net_num
                    ))

                for via_pos in path.vias:
                    pcb.add_via(Via(
                        position=via_pos,
                        size=0.8,
                        drill=0.4,
                        net=net_num
                    ))

        write_kicad_pcb(pcb, args.output)
        print(f"Written to: {args.output}")


def cmd_visualize(args):
    """Execute visualize command."""
    board = Board.from_kicad(args.input)

    if args.format == "ascii":
        output = visualize_ascii(board, scale=args.scale, layer=args.layer)
        if args.output:
            Path(args.output).write_text(output)
        else:
            print(output)

    elif args.format == "svg":
        output = visualize_svg(board, scale=args.scale if args.scale != 2.0 else 10.0)
        if args.output:
            Path(args.output).write_text(output)
            print(f"Written to: {args.output}")
        else:
            print(output)


def cmd_dump_pads(args):
    """Execute dump-pads command."""
    board = Board.from_kicad(args.input)

    if args.format == "json":
        output = {
            "pads": [
                {
                    "component": pad.component,
                    "pad": pad.number,
                    "net": pad.net,
                    "x": round(pad.position[0], 3),
                    "y": round(pad.position[1], 3),
                    "size": [round(s, 3) for s in pad.size],
                    "shape": pad.shape,
                    "type": pad.pad_type
                }
                for pad in board.pads
            ],
            "nets": {
                name: [[p.component, p.number] for p in net.pads]
                for name, net in board.nets.items()
                if net.pads
            },
            "obstacles": [
                {
                    "type": obs.type,
                    "x": round(obs.position[0], 3),
                    "y": round(obs.position[1], 3),
                    "radius": round(obs.radius, 3) if obs.radius else None
                }
                for obs in board.obstacles
            ],
            "board": {
                "width": round(board.width, 3),
                "height": round(board.height, 3)
            }
        }
        text = json.dumps(output, indent=2)

    elif args.format == "csv":
        lines = ["component,pad,net,x,y,width,height,shape,type"]
        for pad in board.pads:
            lines.append(
                f"{pad.component},{pad.number},{pad.net or ''},"
                f"{pad.position[0]:.3f},{pad.position[1]:.3f},"
                f"{pad.size[0]:.3f},{pad.size[1]:.3f},"
                f"{pad.shape},{pad.pad_type}"
            )
        text = '\n'.join(lines)

    if args.output:
        Path(args.output).write_text(text)
        print(f"Written to: {args.output}")
    else:
        print(text)


if __name__ == "__main__":
    main()

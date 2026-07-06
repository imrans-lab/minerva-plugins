#!/usr/bin/env python3
"""
Test script to demonstrate bus routing with hints on the smart-remote board.
"""

import sys

from agent_router import (
    Board, design_review, route_board_with_hints,
    load_hints, write_kicad_pcb, load_kicad_pcb,
    visualize_svg, TraceSegment
)

def main():
    # Paths
    pcb_file = "/home/imran/gitlab/ccsandbox/smart-remote/eda/output/smart_remote_board.kicad_pcb"
    hints_file = "/tmp/smart_remote_hints.yaml"
    output_pcb = "/tmp/smart_remote_bus_routed.kicad_pcb"
    output_svg = "/tmp/smart_remote_bus_routed.svg"

    print("=" * 60)
    print("Bus Routing Test with Hints")
    print("=" * 60)

    # Load board
    print(f"\n1. Loading board from: {pcb_file}")
    board = Board.from_kicad(pcb_file)
    print(f"   Board size: {board.width:.1f}mm x {board.height:.1f}mm")
    print(f"   Pads: {len(board.pads)}")
    print(f"   Nets: {len(board.nets)}")

    # Run design review first
    print("\n2. Running design review...")
    review = design_review(board)
    print(review.print_report())

    # Load hints
    print(f"\n3. Loading hints from: {hints_file}")
    hints = load_hints(hints_file)
    print(f"   Buses defined: {len(hints.buses)}")
    for bus in hints.buses:
        print(f"     - {bus.name}: {bus.nets}")
        if bus.waypoints:
            print(f"       Waypoints: {[(w.x, w.y) for w in bus.waypoints]}")

    # Route with hints
    print("\n4. Routing with hints...")
    result = route_board_with_hints(
        board,
        hints,
        single_layer=True,  # Try single layer first
        trace_width=0.25,
        clearance=0.2
    )

    print(f"\n5. Routing Results:")
    print(f"   Success: {result.success}")
    print(f"   Routes: {len(result.routes)}")
    print(f"   Vias: {result.via_count}")
    print(f"   Unrouted: {len(result.unrouted)}")

    if result.unrouted:
        print("\n   Unrouted connections:")
        for net, pad1, pad2 in result.unrouted[:10]:
            print(f"     - {net}: {pad1.component}.{pad1.number} -> {pad2.component}.{pad2.number}")
        if len(result.unrouted) > 10:
            print(f"     ... and {len(result.unrouted) - 10} more")

    # Show bus routes specifically
    print("\n6. Bus routes:")
    for bus in hints.buses:
        for net in bus.nets:
            route = result.get_route(net)
            if route:
                seg_count = len(route.segments)
                print(f"   {net}: {seg_count} segments")
            else:
                print(f"   {net}: NOT ROUTED")

    # Write output files
    print(f"\n7. Writing output...")

    # Write routed PCB
    kicad_pcb = load_kicad_pcb(pcb_file)
    for route in result.routes:
        for path in route.paths:
            for segment in path.segments:
                kicad_pcb.add_segment(TraceSegment(
                    start=segment.start,
                    end=segment.end,
                    width=0.25,
                    layer=segment.layer,
                    net=kicad_pcb.get_net_number(route.net)
                ))
    write_kicad_pcb(kicad_pcb, output_pcb)
    print(f"   PCB written to: {output_pcb}")

    # Write SVG visualization
    svg = visualize_svg(board, routes=result.routes)
    with open(output_svg, 'w') as f:
        f.write(svg)
    print(f"   SVG written to: {output_svg}")

    print("\n" + "=" * 60)
    print("Done!")
    print("=" * 60)

    return result.success


if __name__ == "__main__":
    success = main()
    sys.exit(0 if success else 1)

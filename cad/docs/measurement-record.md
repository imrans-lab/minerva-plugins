# Measurement record v0

A UTF-8 JSON file carries nominal measurements from any measuring source to a
CAD author. The agent passes the file; no direct plugin call is required.
Dimensions are measured values in millimetres. Manufacturing fit, clearance,
shrinkage and design intent belong in the consuming model. Do not add an
allowance to a measured size.

The four top-level fields are `part`, `frame`, `features` and `still_needed`.
Objects use exactly the fields listed here; unknown fields are refused in v0.
Numbers must be finite; booleans are not numbers.

- `part`: nonempty `name`, and `units` (`"mm"` only).
- `frame`: `origin` (three numbers in mm) and `axes` with `x`, `y` and `z`
  unit vectors, orthogonal and right-handed. Every feature uses this frame.
  Place this chosen part datum explicitly in an assembly.
- `features`: objects with unique nonempty `id`, `kind`, `params`, `sigma` and
  `source`. `source` has `kind` (`photo`, `laser`, `caliper` or `manual`) and
  nonempty `reference`, naming the evidence or notebook entry.
- `still_needed`: objects with nonempty `param`, `reason` and `suggest`.
  `param` names the missing feature parameter; `reason` is `"below resolution"`,
  `"occluded"` or `"not measured"`; `suggest` gives a concrete next measurement.
  Missing dimensions are not invented or set to zero.

`params` has exactly these numeric keys for its kind:

| Kind | Parameters | Meaning |
| --- | --- | --- |
| `plane_height` | `z` | Plane parallel to frame XY at height z. |
| `outline_rect` | `x`, `y`, `width`, `depth` | Axis-aligned rectangle centred at x/y; positive width along X, depth along Y. |
| `slot` | `x`, `y`, `width`, `length`, `angle_deg` | Capsule slot centred at x/y in XY; positive width and overall length, long axis counterclockwise from +X. Angle is in degrees. |
| `point` | `x`, `y`, `z` | Measured location in the part frame. |

`sigma` has exactly the same keys as `params`. Each value is a finite,
nonnegative one-standard-deviation uncertainty in the parameter's unit (mm, or
degrees for `angle_deg`). Zero explicitly claims zero uncertainty; omission
never means zero. Uncertainty is not a manufacturing allowance.

The pure worker function
`mcad_worker.measurement_record.validate_record(decoded_json)` returns a list
of path-qualified errors, or `[]` for a valid record. Future file readers call
it before consuming a record. No separate validation MCP tool is added. V0
does not merge records or include raw point clouds, desired tolerances, circles,
cylinders, spheres or distances.

## Example: purchased battery box

Plausible numbers, not a product specification. Origin is the underside centre;
+X runs along width, +Y along depth, +Z up. The purchased part is nominal; a
printed mating bay declares its process allowance separately. The switch slot
is still occluded.

```json
{
  "part": {"name": "two-cell battery box", "units": "mm"},
  "frame": {
    "origin": [0, 0, 0],
    "axes": {"x": [1, 0, 0], "y": [0, 1, 0], "z": [0, 0, 1]}
  },
  "features": [
    {
      "id": "body", "kind": "outline_rect",
      "params": {"x": 0, "y": 0, "width": 68.4, "depth": 32.2},
      "sigma": {"x": 0.1, "y": 0.1, "width": 0.1, "depth": 0.1},
      "source": {"kind": "caliper", "reference": "notebook: battery-box/external"}
    },
    {
      "id": "top", "kind": "plane_height",
      "params": {"z": 18.6}, "sigma": {"z": 0.1},
      "source": {"kind": "caliper", "reference": "notebook: battery-box/height"}
    },
    {
      "id": "mount_slot", "kind": "slot",
      "params": {"x": 0, "y": -11.2, "width": 3.2, "length": 8.4, "angle_deg": 0},
      "sigma": {"x": 0.1, "y": 0.1, "width": 0.05, "length": 0.1, "angle_deg": 0.5},
      "source": {"kind": "caliper", "reference": "notebook: battery-box/mount-slot"}
    },
    {
      "id": "wire_exit", "kind": "point",
      "params": {"x": 34.2, "y": 0, "z": 7.2},
      "sigma": {"x": 0.1, "y": 0.5, "z": 0.2},
      "source": {"kind": "manual", "reference": "notebook: battery-box/wire-centre"}
    }
  ],
  "still_needed": [
    {"param": "switch_slot.width", "reason": "occluded", "suggest": "Expose the switch opening and measure its width with calipers."}
  ]
}
```

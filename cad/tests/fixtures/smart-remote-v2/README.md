# smart-remote-v2 enclosure fixtures

The real-board fixture set the CAD geometry checks are exercised on: three
enclosure revisions, the board the pcb plugin exported, and stand-in meshes for
the off-board parts. Filed reproductions name these files, so they live here
rather than in a scratch directory.

| File | What it is |
| --- | --- |
| `enclosure-rev1.mcad` | revision 1 |
| `enclosure.mcad` | revision 2 |
| `enclosure-rev3.mcad` | revision 3 — flat remote, crowned skin, raised centre section |
| `smart-remote-v2.glb` | the board, exported by the pcb plugin (~2.9 MB, glTF units: metres, Y up) |
| `parts/*.glb`, `parts/*.stl` | the six off-board stand-ins (1–150 KB each) |

Paths inside the `.mcad` files are relative to the `.mcad` file, and this layout
keeps them exactly as they were authored — no path was rewritten in the copies.
Both a `.glb` and an `.stl` are kept for the OLED, the speaker and the AA holder
because the `.mcad` sources reference the `.stl` for those three. Each revision
poses the board plus five parts; the 1S LiPo stand-in is the alternative power
source and no revision currently references it.

## The stand-ins are not vendor models

Every mesh under `parts/` was modelled from the part's datasheet dimensions. They
are approximations of the envelope, not the vendor's CAD: fillets, connector
detail, silkscreen and component-level geometry are absent, and small features
may be off by a fraction of a millimetre. Do not grade a real part's fit against
them, and do not treat a clearance measured against one as a manufacturing
result — re-check against the vendor model before committing to a print.

The KY-023 thumbstick stand-in (`parts/joystick_ky023.glb`) is deliberately
tall: its cap top sits 41.6 mm above the mesh origin. That is a worst-case
stack chosen so the shell has to clear the tallest plausible stick, not a
measurement of any one vendor's part.

Each stand-in's origin is the centre of its footprint at its underside, and the
`.mcad` sources load them with `units="mm", up="z"` — which overrides the glTF
default of metres and Y-up, so the files are authored in millimetres.

| Part | Size (x, y, z mm) |
| --- | --- |
| `esp32_s3_devkitc1.glb` | 25.4 x 65.0 x 4.9 (origin offset in y) |
| `oled_096` | 27.0 x 27.0 x 2.8 |
| `joystick_ky023.glb` | 26.0 x 34.0 x 41.6 |
| `speaker_28mm` | 28.0 x 28.0 x 5.5 |
| `holder_4xaa_2x2` | 62.0 x 57.0 x 17.25 |
| `lipo_1s_50x34x6.glb` | 50.0 x 34.0 x 6.0 |

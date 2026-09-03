"""The per-side texture bake: what it measures, and where it is registered.

A picture is the one artifact whose defects are invisible to the thing that
produced it. A board rendered at half the requested scale still looks like a
board; a bottom face that forgot to mirror looks perfect and is BACKWARDS. So
every test here measures the produced pixels against numbers taken from the
board document and the footprint file — never against the renderer's own
arithmetic.

THE FIXTURE IS THE SHIPPED COUPON (``testdata/coupon_jlc1.yaml``), because it
already carries every feature class this bake has to draw and, more usefully,
carries them ASYMMETRICALLY:

  * ``FID1`` — a 1.0 mm circular land at board (2, 2) with a 0.5 mm solder-mask
    margin (``Minerva_Fixture.pretty/FID_Circle_1mm.kicad_mod``). Known size at
    a known place: the scale and origin oracle.
  * the cutout at x 10.8..13.8, y 5..11 — off centre on BOTH axes, so a mirror
    applied to the wrong axis, or not applied, lands somewhere else.
  * the bottom-side copper pour over x 1..9.5 — copper that exists on ONE face
    and on one half of the board, which is what makes the mirror check decisive
    rather than merely consistent.

The board is 24 x 18 mm, so at the default 20 px/mm every millimetre is exactly
20 pixels and each expectation below is arithmetic a reader can do by hand.
"""

from __future__ import annotations

import copy
from pathlib import Path

import yaml

from pcb_worker import texture_bake
from pcb_worker.compile_board import compile_board
from pcb_worker.gerber import build_gerbers_ir
from pcb_worker.resolved_board import ResolutionSuccess, ResolvedFabrication
from pcb_worker.texture_appearance import NEUTRAL, appearance_for
from pcb_worker.texture_frame import MAX_TEXTURE_PX, TextureFrame

COUPON = Path(__file__).resolve().parent / "testdata" / "coupon_jlc1.yaml"

BOARD_W_MM, BOARD_H_MM = 24.0, 18.0
FID1_MM = (2.0, 2.0)          # board position of the 1.0 mm fiducial land
FID1_DIAMETER_MM = 1.0
CUTOUT_X_MM = (10.8, 13.8)    # the interior opening, off centre on both axes
CUTOUT_Y_MM = (5.0, 11.0)
POUR_PROBE_MM = (2.0, 16.0)   # inside the bottom-side pour (x 1..9.5, y 8.6..17.5)


#: A keepout dropped INSIDE the bottom pour, clear of every trace, pad and bore
#: on that face, so the copper around it is uniform on both axes. It is what
#: gives the pour an internal VOID — the shape the fill emits as a self-touching
#: keyhole contour rather than as a simple ring.
VOID_X_MM = (2.0, 4.0)
VOID_Y_MM = (12.5, 14.5)
VOID_ZONE = {
    "id": "zone:0f0e0d0c0b0a09080706050403020100",
    "kind": "keepout",
    "layer": "bottom",
    "outline": [{"x_mm": VOID_X_MM[0], "y_mm": VOID_Y_MM[0]},
                {"x_mm": VOID_X_MM[1], "y_mm": VOID_Y_MM[0]},
                {"x_mm": VOID_X_MM[1], "y_mm": VOID_Y_MM[1]},
                {"x_mm": VOID_X_MM[0], "y_mm": VOID_Y_MM[1]}],
}


def _board(**fabrication) -> dict:
    board = yaml.safe_load(COUPON.read_text(encoding="utf-8"))
    if fabrication:
        board["fabrication"] = dict(fabrication)
    return board


def _compiled(board: dict):
    result = compile_board(copy.deepcopy(board))
    assert isinstance(result, ResolutionSuccess), \
        [(d.code, d.message) for d in result.diagnostics]
    return result.board


def _run_of_colour(image, row: int, rgb, window: range) -> list[int]:
    """Columns on ``row`` painted exactly ``rgb`` — a feature's measured width."""
    pixels = image.load()
    return [x for x in window if pixels[x, row][:3] == rgb]


def _transparent_columns(image, row: int, window: range) -> list[int]:
    """Columns on ``row`` where the board is absent (cutout or bore)."""
    alpha = image.getchannel("A").load()
    return [x for x in window if alpha[x, row] == 0]


def _transparent_rows(image, column: int, window: range) -> list[int]:
    """Rows on ``column`` where the board is absent."""
    alpha = image.getchannel("A").load()
    return [y for y in window if alpha[column, y] == 0]


def test_a_known_feature_measures_its_true_size_at_the_pixel_it_belongs_at():
    """MUTATION THIS CATCHES: any scale or origin error — a factor-of-two
    resolution, an off-by-a-board-height origin, a millimetre/inch mix-up.

    ORACLE: the coupon says the board is 24 x 18 mm and puts FID1 at (2, 2);
    FID_Circle_1mm.kicad_mod says its land is a 1.0 mm circle with a 0.5 mm mask
    margin. So the plated disc — the finish colour shows exactly where a mask
    opening exposes copper, and the opening here is wider than the land — is
    ``scale`` pixels across, centred ``2 * scale`` from the top-left corner. Both
    scales are checked because a single scale cannot distinguish a correct
    mapping from one that ignores the caller's request.
    """
    board = _compiled(_board())

    for scale in (20, 40):
        baked = texture_bake.bake_side(board, "top", scale_px_per_mm=scale)

        assert baked.image.size == (int(BOARD_W_MM * scale), int(BOARD_H_MM * scale))
        assert baked.frame.scale_px_per_mm == scale
        assert baked.notes == ()

        centre_x, centre_y = int(FID1_MM[0] * scale), int(FID1_MM[1] * scale)
        run = _run_of_colour(baked.image, centre_y, baked.appearance.finish,
                             range(0, centre_x * 3))
        assert run, f"no plated pixels on FID1's centre row at {scale} px/mm"

        measured = len(run)
        expected = FID1_DIAMETER_MM * scale
        assert abs(measured - expected) <= 1, (
            f"FID1's 1.0 mm land measured {measured} px at {scale} px/mm; "
            f"expected {expected:g} +/- 1")
        midpoint = (run[0] + run[-1]) / 2.0
        assert abs(midpoint - centre_x) <= 1, (
            f"FID1 is centred on column {midpoint} at {scale} px/mm; "
            f"board (2, 2) is column {centre_x}")


def test_silk_survives_the_default_resolution():
    """NOT a legibility RULE — GC9 owns that, in vector, once. This records what
    the default scale actually delivers, which is the question the caller asks
    when choosing one.

    ORACLE: the profile's published silk floor is 0.15 mm, so at 20 px/mm a
    minimum-width stroke is 3 px. The bake oversamples and box-filters, so the
    saturated CORE of such a stroke is 2-3 px with antialiased edges either side.
    Both faces carry silk on this board (designators and the owl on top, the
    ``REV A`` legend on the bottom), so a face rendering none is a bug.
    """
    board = _compiled(_board())
    baked = texture_bake.bake_board(board)

    for side, face in baked.items():
        ink = face.appearance.silk
        pixels = face.image.load()
        width, height = face.image.size
        cores: list[int] = []
        for x in range(width):
            run = 0
            for y in range(height):
                if pixels[x, y][:3] == ink:
                    run += 1
                else:
                    if run:
                        cores.append(run)
                    run = 0
            if run:
                cores.append(run)
        assert cores, f"{side} face rendered no silk at all"
        assert max(cores) >= 2, (
            f"{side} face's widest silk stroke has a {max(cores)} px core at the "
            f"default scale; a 0.15 mm line should hold 2-3")


def test_the_bottom_face_mirrors_the_top_and_shows_its_own_copper():
    """MUTATION THIS CATCHES: the bottom face not mirrored, mirrored on Y
    instead of X, or drawn from the top face's buckets. Each of those produces
    an image that looks entirely plausible.

    TWO ORACLES, both from the coupon document:

      * the cutout is a hole in the board at x 10.8..13.8. Seen from the top it
        starts 10.8 mm from the LEFT edge; seen from below it starts
        24 - 13.8 = 10.2 mm from the left. Its width and its rows are identical
        on both faces — a Y mirror would move the rows, and no mirror at all
        would leave the columns unmoved.
      * the copper pour lives on the BOTTOM layer over x 1..9.5. On the bottom
        face that copper must read through the mask at the MIRRORED column and
        must not be there at the unmirrored one. This is also the evidence that
        the composite shows copper under the mask at all: the two probes differ
        only in what lies beneath the same film.
    """
    scale = 20
    baked = texture_bake.bake_board(_compiled(_board()), scale_px_per_mm=scale)
    top, bottom = baked["top"], baked["bottom"]

    # Columns, measured on a row through the cutout and inside a window that
    # holds no drilled bore (bores are transparent too, and would be read as
    # part of the opening).
    row = int(8.0 * scale)                      # board y = 8 mm
    columns = range(int(9.5 * scale), int(14.5 * scale))
    top_run = _transparent_columns(top.image, row, columns)
    bottom_run = _transparent_columns(bottom.image, row, columns)

    width_px = int((CUTOUT_X_MM[1] - CUTOUT_X_MM[0]) * scale)
    assert len(top_run) == len(bottom_run) == width_px
    assert top_run[0] == int(CUTOUT_X_MM[0] * scale)
    assert bottom_run[0] == int((BOARD_W_MM - CUTOUT_X_MM[1]) * scale)

    # Rows, on a column through the cutout on BOTH faces (board x = 12 mm, which
    # the mirror maps to the same column). Identical on the two faces: the
    # mirror is on X only, and a Y mirror would move this run.
    column = int(12.0 * scale)
    height_px = int((CUTOUT_Y_MM[1] - CUTOUT_Y_MM[0]) * scale)
    for face, image in (("top", top.image), ("bottom", bottom.image)):
        rows = _transparent_rows(image, column, range(0, image.height))
        assert len(rows) == height_px, f"{face} cutout is {len(rows)} px tall"
        assert rows[0] == int(CUTOUT_Y_MM[0] * scale), f"{face} cutout starts at row {rows[0]}"

    pixels = bottom.image.load()
    probe_row = int(POUR_PROBE_MM[1] * scale)
    over_pour = pixels[int((BOARD_W_MM - POUR_PROBE_MM[0]) * scale), probe_row]
    over_laminate = pixels[int(POUR_PROBE_MM[0] * scale), probe_row]
    assert over_pour != over_laminate, (
        "the bottom face paints the same colour over pour copper and over bare "
        "laminate — either the mirror is missing or copper does not read through "
        "the mask film")
    assert over_pour[0] > over_laminate[0], (
        "copper under the mask should read LIGHTER than laminate under the same "
        "film; the probes may be swapped, which is what a missing mirror does")


def test_the_ordered_colour_changes_the_picture_and_nothing_else():
    """MUTATION THIS CATCHES: a colour constant hardcoded in the renderer. Such
    a board renders green forever and no test of the renderer alone can see it.

    ORACLE: the words. A board ordered RED must produce pixels whose red channel
    dominates, and one ordered GREEN pixels whose green channel dominates —
    a property of the colour NAMES, not of any table this repo happens to hold.
    And the pair must emit byte-identical fabrication, which is T1's claim that
    an appearance moves no emitted byte: same board, same copper, different
    picture.
    """
    red = _compiled(_board(mask_colour="Red"))
    green = _compiled(_board(mask_colour="green"))

    assert dict(build_gerbers_ir(red)) == dict(build_gerbers_ir(green)), \
        "the ordered mask colour changed an emitted fabrication file"

    red_image = texture_bake.bake_side(red, "top").image
    green_image = texture_bake.bake_side(green, "top").image
    assert red_image.tobytes() != green_image.tobytes()

    # Board (15, 15): laminate under mask, clear of every feature on this coupon.
    probe = (15 * 20, 15 * 20)
    r = red_image.load()[probe]
    g = green_image.load()[probe]
    assert r[0] > r[1], f"a board ordered red painted {r}"
    assert g[1] > g[0], f"a board ordered green painted {g}"


def test_an_unrecognised_appearance_is_neutral_and_says_so():
    """A profile that publishes no menu accepts any colour, so a board can carry
    one we have no swatch for. Drawing it green would be a lie; refusing to draw
    the board would be the wrong trade for a picture."""
    appearance = appearance_for(ResolvedFabrication(
        mask_colour="Matte Aubergine", finish="Immersion Unobtainium", thickness_mm=1.6))

    assert appearance.mask == NEUTRAL
    assert appearance.finish == NEUTRAL
    assert len(appearance.notes) == 2
    assert any("Matte Aubergine" in note for note in appearance.notes)


def test_the_resolution_cap_clamps_the_scale_and_admits_it():
    """MUTATION THIS CATCHES: a cap that crops the board, or one that silently
    keeps the requested scale in the frame while rasterising at another — which
    would misregister every consumer that trusts the frame.

    Frame arithmetic only: allocating a capped image to prove a division is the
    expensive way to learn nothing extra.
    """
    frame = TextureFrame.for_board((0.0, 0.0), (400.0, 300.0), "top",
                                   scale_px_per_mm=50.0)

    assert frame.clamped
    assert frame.requested_scale_px_per_mm == 50.0
    assert frame.width_px == MAX_TEXTURE_PX
    assert frame.scale_px_per_mm == MAX_TEXTURE_PX / 400.0
    assert frame.height_px == 6144

    # Registration is still exact AT THE CLAMPED SCALE — the corners land on the
    # corners and the mapping inverts.
    assert frame.board_to_pixel(0.0, 0.0) == (0.0, 0.0)
    assert frame.board_to_pixel(400.0, 0.0)[0] == float(MAX_TEXTURE_PX)
    round_trip = frame.pixel_to_board(*frame.board_to_pixel(123.4, 56.7))
    assert abs(round_trip[0] - 123.4) < 1e-9 and abs(round_trip[1] - 56.7) < 1e-9

    uncapped = TextureFrame.for_board((0.0, 0.0), (24.0, 18.0), "top",
                                      scale_px_per_mm=50.0)
    assert not uncapped.clamped
    assert (uncapped.width_px, uncapped.height_px) == (1200, 900)


def test_a_pour_with_an_internal_void_is_painted_with_the_void_open():
    """MUTATION THIS CATCHES: a rasteriser that fills a pour contour with the
    NON-ZERO winding rule instead of even-odd. Copper zone fill emits a region
    with a hole in it as ONE self-touching keyhole ring — an outer boundary, a
    bridge in to the void, the void walked the other way, and the bridge back —
    because the Gerber region primitive cannot express a hole. Filled by
    winding, that ring comes out SOLID: the void disappears and the picture
    shows copper where the board has none. Every pour on the coupon is simple,
    so nothing else here would ever see it.

    ORACLE: the keepout is 2.0 x 2.0 mm at board x 2..4, y 12.5..14.5, and a
    keepout subtracts from a pour with no clearance inflation, so the void is
    exactly the rectangle authored. At 20 px/mm that is 40 px, measured on a row
    and a column through its middle, with pour copper on both sides of each —
    and the SAME pixel is copper on the board without the keepout, which is what
    proves the run is the void and not the probe having wandered off the pour.
    """
    scale = 20
    solid = _compiled(_board())
    board = _board()
    board["zones"] = board["zones"] + [copy.deepcopy(VOID_ZONE)]
    voided = _compiled(board)

    def face(compiled):
        return texture_bake.bake_side(compiled, "bottom", scale_px_per_mm=scale)

    def at(image, x_mm: float, y_mm: float):
        # The bottom face is mirrored on X, which is why every probe here is
        # written in BOARD millimetres and mapped through the same reflection.
        return image.load()[int((BOARD_W_MM - x_mm) * scale), int(y_mm * scale)][:3]

    with_void, without_void = face(voided).image, face(solid).image
    centre = ((VOID_X_MM[0] + VOID_X_MM[1]) / 2.0,
              (VOID_Y_MM[0] + VOID_Y_MM[1]) / 2.0)

    copper = at(without_void, *centre)
    assert at(with_void, *centre) != copper, (
        "the void was painted as copper — a keyhole contour filled solid")
    assert at(with_void, *centre) == at(with_void, 18.0, centre[1]), (
        "the void is not the bare-laminate colour the rest of the board shows")

    # The void's WIDTH and HEIGHT, measured through its middle. A window inside
    # the pour on both axes, so anything not copper is the void itself.
    row = int(centre[1] * scale)
    columns = range(int((BOARD_W_MM - 9.5) * scale), int((BOARD_W_MM - 1.0) * scale))
    open_columns = [x for x in columns
                    if with_void.load()[x, row][:3] != copper]
    column = int((BOARD_W_MM - centre[0]) * scale)
    rows = range(int(10.5 * scale), int(17.4 * scale))   # clear of the pad bore
    open_rows = [y for y in rows if with_void.load()[column, y][:3] != copper]

    for measured, span, axis in ((open_columns, VOID_X_MM, "wide"),
                                 (open_rows, VOID_Y_MM, "tall")):
        expected = (span[1] - span[0]) * scale
        assert abs(len(measured) - expected) <= 2, (
            f"the void measures {len(measured)} px {axis}; the keepout is "
            f"{expected:g} px")
        assert measured[-1] - measured[0] == len(measured) - 1, (
            f"the void is not one contiguous run {axis}")

    # And the pour it sits in is still copper right up to it.
    assert at(with_void, VOID_X_MM[0] - 0.5, centre[1]) == copper
    assert at(with_void, VOID_X_MM[1] + 0.5, centre[1]) == copper

"""What the ORDERED appearance looks like, as colour — the swatch table the
board raster paints with.

The bake never names a colour. It asks this module, and this module answers from
the board's own :class:`resolved_board.ResolvedFabrication` — the mask colour and
surface finish THIS BOARD WAS ORDERED IN. Separating the two is the point: a
renderer holding a green constant renders every board green and is wrong the day
somebody orders black, and no test of the renderer can catch it because the
renderer agrees with itself.

WHAT IS AND IS NOT A CHOICE HERE. Three of the five colours below come from the
order: the mask, the finish that shows in the mask openings, and (by the vendor's
own rule) the silk. Two do not, because nothing on the order form selects them:
the bare FR4 laminate and the copper under the mask. Those are properties of the
materials every one of these boards is made of, so they are constants — but
constants in the SWATCH table, where a reader looking for "what colour is this
board" finds them, not scattered through drawing code.

UNKNOWN NAMES ARE NEUTRAL AND SAID OUT LOUD, not fatal. A board's mask colour is
validated against the selected profile's published menu only when that profile
publishes one (see ``manufacturer_profile.appearance_refusal``), so a board can
legitimately carry a colour we have no swatch for. Refusing to draw the board at
all would be the wrong trade for a picture; drawing it green would be a lie.
It renders in a neutral grey and the note says which value was unrecognised.
"""

from __future__ import annotations

from dataclasses import dataclass

from .resolved_board import ResolvedFabrication

RGB = tuple[int, int, int]

#: Bare laminate, where the mask is absent and there is no copper. Not an
#: ordered choice — it is what FR4 looks like.
FR4_SUBSTRATE: RGB = (0x8C, 0x70, 0x47)

#: Bare copper, as it shows where nothing covers it: an OSP finish is a clear
#: organic coat, so its mask openings show this.
BARE_COPPER: RGB = (0xD9, 0x8C, 0x47)

#: Copper as it sits UNDER the mask film. Much PALER than bare copper on
#: purpose: the film above it keeps ``MASK_ALPHA`` of its own colour and lets
#: only the remainder of this through, and on a real board the poured and
#: routed copper reads as the plainly brighter regions through the lacquer.
#: The value is chosen so that copper under the film clears
#: :func:`contrast_under_film` on every published mask colour — a tone that
#: merely looked like copper (the bare swatch above) came through a green film
#: at 7 % luminance contrast, which is invisible at a glance.
UNDER_MASK_COPPER: RGB = (0xFA, 0xE6, 0xC0)

#: Opacity of the solder-mask film over whatever is beneath it. Mask is a
#: translucent lacquer, not paint: at 1.0 the copper vanishes and the picture
#: stops showing the board; at much below 0.6 the mask colour stops reading as
#: the colour that was ordered.
MASK_ALPHA = 0.72

#: Solder-mask swatches, keyed by the CASEFOLDED vendor vocabulary. The keys are
#: the seven JLCPCB publishes and the shipped profiles offer
#: (``library/profiles/jlcpcb-*.json`` capabilities.mask_colours); a vendor that
#: publishes a colour not listed here still renders, in the neutral swatch.
MASK_SWATCHES: dict[str, RGB] = {
    "green": (0x0E, 0x6B, 0x3D),
    "red": (0x9E, 0x1B, 0x1B),
    "blue": (0x12, 0x3F, 0x8F),
    "yellow": (0xC8, 0xA8, 0x14),
    "purple": (0x4B, 0x1F, 0x6B),
    "white": (0xE8, 0xE8, 0xE4),
    "black": (0x1A, 0x1A, 0x1A),
}

#: Surface-finish swatches — the colour that shows THROUGH a mask opening, which
#: is the plating on the exposed copper rather than the copper itself. Keyed
#: casefolded, same as the mask.
FINISH_SWATCHES: dict[str, RGB] = {
    "hasl": (0xC2, 0xC6, 0xCA),          # tin/lead or lead-free solder: dull silver
    "enig": (0xD8, 0xB4, 0x54),          # immersion gold over nickel
    "osp": BARE_COPPER,                  # a clear organic coat: bare copper shows
}

#: What an unrecognised mask colour or finish renders as. Neutral on purpose —
#: it should look like "we do not know", not like some other board house's green.
NEUTRAL: RGB = (0x77, 0x77, 0x77)

#: Silkscreen ink. The vendor prints white legend on every mask colour except a
#: white one, where it prints black — a rule of the process, not a choice on the
#: order form, which is why it is derived from the ordered mask colour here
#: rather than being a fourth field nobody would ever set.
SILK_ON_DARK: RGB = (0xEC, 0xEC, 0xEC)
SILK_ON_LIGHT: RGB = (0x1E, 0x1E, 0x1E)

#: Mask colours the vendor prints BLACK legend on (casefolded).
_LIGHT_MASKS = frozenset({"white", "yellow"})


@dataclass(frozen=True)
class Appearance:
    """The five colours one side of a board is painted with, plus what could not
    be resolved. ``notes`` is empty for every board whose ordered values are in
    the tables above."""

    substrate: RGB
    copper: RGB
    mask: RGB
    mask_alpha: float
    finish: RGB
    silk: RGB
    notes: tuple[str, ...] = ()


def appearance_for(fabrication: ResolvedFabrication) -> Appearance:
    """Swatches for one board's ordered appearance.

    Takes the IR dataclass, not anything shaped like it: ``ResolvedFabrication``
    already guarantees a non-empty colour and finish in its ``__post_init__``, so
    the fields are read directly and the only thing left to handle is a name
    with no swatch.

    Thickness is deliberately unread: it is an ordered fact about the board, but
    it is not visible in a picture of one face. The 3D slab is where it matters.
    """
    notes: list[str] = []

    mask_name = fabrication.mask_colour.strip().casefold()
    mask = MASK_SWATCHES.get(mask_name)
    if mask is None:
        notes.append(
            f"solder-mask colour {fabrication.mask_colour!r} has no swatch; "
            f"rendered neutral. Known: {', '.join(sorted(MASK_SWATCHES))}")
        mask = NEUTRAL

    finish_name = fabrication.finish.strip().casefold()
    finish = FINISH_SWATCHES.get(finish_name)
    if finish is None:
        notes.append(
            f"surface finish {fabrication.finish!r} has no swatch; "
            f"rendered neutral. Known: {', '.join(sorted(FINISH_SWATCHES))}")
        finish = NEUTRAL

    return Appearance(
        substrate=FR4_SUBSTRATE,
        copper=UNDER_MASK_COPPER,
        mask=mask,
        mask_alpha=MASK_ALPHA,
        finish=finish,
        silk=SILK_ON_LIGHT if mask_name in _LIGHT_MASKS else SILK_ON_DARK,
        notes=tuple(notes),
    )


def under_film(appearance: Appearance, base: RGB) -> RGB:
    """The colour ``base`` shows as through the mask film — the same alpha
    composite the rasteriser paints, as arithmetic, so a report can state the
    two tones a face is mostly made of without reading pixels back."""
    a = appearance.mask_alpha
    return tuple(int(round(a * m + (1.0 - a) * b))
                 for m, b in zip(appearance.mask, base))  # type: ignore[return-value]


def luminance(rgb: RGB) -> float:
    """Rec. 601 luma of an sRGB triple: what a person reads as brightness."""
    r, g, b = rgb
    return 0.299 * r + 0.587 * g + 0.114 * b


def contrast_under_film(appearance: Appearance) -> float:
    """Luminance of copper under the film over luminance of laminate under it.

    This is the number that decides whether traces can be read at a glance:
    1.0 means copper and laminate paint the same tone and the picture shows no
    copper at all.
    """
    return (luminance(under_film(appearance, appearance.copper))
            / luminance(under_film(appearance, appearance.substrate)))

# Part-orientation coverage

**This file is GENERATED. Do not hand-edit it.**

Regenerate with:

    python3 pcb/scripts/gen_part_orientation.py

Every footprint in the acquisition lock (`pcb/library/footprints.lock.json`),
folded against the part-orientation ledger (`pcb/library/part_orientation.json`).

A pick-and-place machine reads a position file's rotation against the VENDOR's
drawing of the part, not against our `.kicad_mod`. `pcb_worker.assembly_orientation`
therefore REFUSES to emit a rotation for a part bought as a catalogue number
whose pair nobody has measured. This file is that refusal's contents, listed
ahead of time: the **UNKNOWN** section below is the set of drawings an order
could still stop on.

An unknown footprint is not a defect. It is a drawing nobody has yet paired
with a real vendor drawing of a real catalogue part, and it stays unknown until
somebody does — closing it by declaring "no vendor drawing exists" for a
genuine purchasable package would disarm the gate for every part placed on that
drawing, which is far worse than the gap.

## Summary

| state | footprints |
| --- | --- |
| measured | 11 |
| declared no-reference | 10 |
| **unknown** | **21** |
| total in the acquisition lock | 42 |

## UNKNOWN — nothing has ever measured this drawing

An order that buys a catalogue part on one of these refuses with `assembly_orientation_unknown`. To close one, add the vendor's package payload for the part it is bought as to `pcb/worker/tests/testdata/vendor_footprints/`, pair it in that directory's `index.json`, and regenerate. Where the lock already names a catalogue number it is repeated below as a LEAD — it is not a pairing and nothing has been measured against it.

- `Adafruit:MAX98357A_I2S_1x7_P2.54mm` — the lock names no catalogue part for it
- `Adafruit:MAX98357A_I2S_1x7_P2.54mm_WithTerminals` — the lock names no catalogue part for it
- `Capacitor_SMD:C_0402_1005Metric` — the lock names no catalogue part for it
- `Capacitor_SMD:C_1206_3216Metric` — the lock names no catalogue part for it
- `Capacitor_SMD:C_1210_3225Metric` — the lock names no catalogue part for it
- `Connector_JST:JST_PH_S2B-PH-K_1x02_P2.00mm_Horizontal` — the lock names no catalogue part for it
- `Connector_PinHeader_2.54mm:PinHeader_1x02_P2.54mm_Vertical` — the lock names no catalogue part for it
- `Connector_PinSocket_2.54mm:PinSocket_1x04_P2.54mm_Vertical` — the lock names no catalogue part for it
- `Connector_PinSocket_2.54mm:PinSocket_1x05_P2.54mm_Vertical` — the lock names no catalogue part for it
- `Connector_PinSocket_2.54mm:PinSocket_1x07_P2.54mm_Vertical` — the lock names no catalogue part for it
- `Connector_PinSocket_2.54mm:PinSocket_1x20_P2.54mm_Vertical_SMD_Wcon2171_TYPE2` — the lock names no catalogue part for it
- `Diode_SMD:D_SMA` — the lock names no catalogue part for it
- `EVP-ASAC1A:SW_EVP-ASAC1A` — the lock names no catalogue part for it
- `Espressif:ESP32-S3-DevKitC` — the lock names no catalogue part for it
- `Espressif:ESP32-S3-DevKitC-1_SocketSet_2x22_THT` — the lock names `C41376161`, `HC-PM254-8.5H-1x22P`
- `INMP441:INMP441_I2S_2x3_P2.54mm` — the lock names no catalogue part for it
- `Inductor_SMD:L_Vishay_IFSC-1515AH_4x4x1.8mm` — the lock names no catalogue part for it
- `MEMSensing:MSM261S4030H0R_TopPort_LGA-8_4x3mm` — the lock names no catalogue part for it
- `Package_DIP:DIP-6_W7.62mm_Socket` — the lock names no catalogue part for it
- `Resistor_SMD:R_0402_1005Metric` — the lock names no catalogue part for it
- `Sunlord:L_Sunlord_AMWPH4018_4x4x1.8mm` — the lock names `AMWPH4018S2R2MT`, `C2846183`

## Measured — compared against a vendor's drawing

- `Capacitor_SMD:C_0805_2012Metric`
  - jlcpcb `C49678` — 0 deg
- `Connector_JST:JST_PH_S2B-PH-SM4-TB_1x02-1MP_P2.00mm_Horizontal`
  - jlcpcb `C295747` — 0 deg
- `Connector_JST:JST_PH_S4B-PH-SM4-TB_1x04-1MP_P2.00mm_Horizontal`
  - jlcpcb `C265102` — 180 deg
- `Connector_JST:JST_PH_S5B-PH-SM4-TB_1x05-1MP_P2.00mm_Horizontal`
  - jlcpcb `C265104` — 180 deg
- `Connector_JST:JST_XH_S4B-XH-SM4-TB_1x04-1MP_P2.50mm_Horizontal`
  - jlcpcb `C161861` — 0 deg
- `Fuse:Fuse_1206_3216Metric`
  - jlcpcb `C2803346` — 0 deg
- `Package_DFN_QFN:VQFN-16-1EP_3x3mm_P0.5mm_EP1.68x1.68mm`
  - jlcpcb `C910544` — 270 deg
- `Package_TO_SOT_SMD:SOT-23`
  - jlcpcb `C15127` — 180 deg
- `Package_TO_SOT_SMD:TSOT-23-6`
  - jlcpcb `C780769` — 270 deg
- `Resistor_SMD:R_0805_2012Metric`
  - jlcpcb `C149504` — 0 deg
- `Syntiant:SPK0641HT4H-1_TopPort_LGA-8_4x3mm`
  - jlcpcb `C5159510` — 180 deg

## Declared no-reference — nothing orderable is drawn like this

A human statement that no vendor sells an oriented part drawn as this land pattern, for ANY catalogue number. These carry no offset and the emitter passes such a part's placed rotation through untouched, so the bar for adding one is that the drawing is genuinely not a purchasable package — a mounting hole, a fiducial, a test point, silk artwork, a DRC coupon fixture, or an in-repo synthesized fixture land. A drawing that stands for several physical parts is NOT one of them: the parts are bought, so the land is measurable pair by pair, and a footprint-wide declaration would emit every one of them unchecked.

- `C_0805` — An in-repo synthesized fixture land, not a package anyone sells. The seed synthesizer draws it for suites that need real resolvable pads, and its ref is kept deliberately BARE (`C_0805`, never `Capacitor_SMD:C_0805`) precisely so no board buying a real 0805 part can resolve to it. The purchasable 0805 land is `Capacitor_SMD:C_0805_2012Metric`, which is measured.
- `Minerva_Fixture:DAM_MinWeb_2P` — A DRC coupon fixture: a deliberate minimum-web solder-mask dam, drawn to be measured by the process check. Nothing orderable corresponds to it.
- `Minerva_Fixture:FID_Circle_1mm` — A fiducial: bare copper the placement machine sights on. Board furniture, not a purchasable part, so there is nothing to compare our drawing with.
- `Minerva_Fixture:LOGO_Owl_TestCoupon` — Silkscreen artwork on the fab coupon. It has lands only incidentally and is not bought from anyone.
- `Minerva_Fixture:SMD_WeirdPads_2P` — A DRC coupon fixture: deliberately awkward SMD lands drawn to exercise the geometric checks. Nothing orderable corresponds to it.
- `Minerva_Fixture:TP_MinAnnular_0p6` — A DRC coupon fixture: a minimum-annular-ring test point drawn to be measured by the process check. Nothing orderable corresponds to it.
- `Minerva_Fixture:TXT_CouponRev` — Silkscreen revision text on the fab coupon. Artwork, not a part.
- `MountingHole:MountingHole_3.2mm_M3` — A plated M3 hole, not a part. Nothing is ever placed here, so there is no pick-and-place rotation to correct and no vendor drawing to correct it against.
- `R_0805` — An in-repo synthesized fixture land, not a package anyone sells, and deliberately NOT the official KiCad `R_0805` drawing. Its ref is kept bare (`R_0805`, never `Resistor_SMD:R_0805`) so no board buying a real 0805 part can resolve to it. The purchasable 0805 land is `Resistor_SMD:R_0805_2012Metric`, which is measured.
- `TH_TestPoint` — A probe pad. It is etched and never populated, so no assembly house ever orients it and no supplier draws it.

## Measured but undecided — covered, and still refused

A pair somebody measured where the drawings did not separate one angle from the next. It states no offset, so the emitter refuses it with `assembly_orientation_undecided`. Listed apart from the measured count because a reader looking for what can stop an order needs both.

_None._

## Rows about footprints the lock no longer carries

_None._

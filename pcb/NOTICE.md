# NOTICE

**This file is GENERATED. Do not hand-edit it.**

Regenerate with:

    python3 pcb/scripts/gen_notice.py

This is the license and attribution inventory for the footprint seed library pinned in `pcb/library/footprints.lock.json` (acquisition-lock schema v2 — see `pcb/docs/libraries.md`). It is the RELEASE gate: an entry with an unresolved (`UNKNOWN`) license, an out-of-vocabulary `source_kind`, or a missing `source_ref` refuses generation outright rather than shipping. One section below per DISTINCT license carried by the shipped lock; each entry lists its footprint ref and its acquisition `source_ref`.

## Apache-2.0

These entries are drawn from Espressif's kicad-libraries, licensed under the Apache License, Version 2.0. Redistribution must retain the copyright notice and this attribution — see https://github.com/espressif/kicad-libraries/blob/master/LICENSE.

- `Espressif:ESP32-S3-DevKitC` — github.com/espressif/kicad-libraries (footprint ESP32-S3-DevKitC) (attribution reconstructed forensically (generator pcbnew, version 20211014, verbatim Espressif descr text); upstream byte-identity NOT re-verified — file predates acquisition tooling)

## CC-BY-SA-4.0 WITH KiCad-libraries-exception

These entries are drawn from KiCad's official libraries (kicad-footprints), licensed CC-BY-SA-4.0 WITH the KiCad-libraries-exception. Redistribution requires attribution to the KiCad project — see https://gitlab.com/kicad/libraries/kicad-footprints/-/blob/master/LICENSE.md for the exception text this NOTICE satisfies.

- `Connector_JST:JST_PH_S2B-PH-K_1x02_P2.00mm_Horizontal` — kicad-footprints official library (KiCad-era .pretty, copied verbatim at cdc060f 2026-07-07) (descr: 'generated with kicad-footprint-generator', tedit 5B7745C6)
- `Connector_PinSocket_2.54mm:PinSocket_1x04_P2.54mm_Vertical` — kicad-footprints official library (KiCad-era .pretty, copied verbatim at cdc060f 2026-07-07) (descr: '(from Kicad 4.0.7), script generated', tedit 5A19A429)
- `Connector_PinSocket_2.54mm:PinSocket_1x05_P2.54mm_Vertical` — kicad-footprints official library (KiCad-era .pretty, copied verbatim at cdc060f 2026-07-07) (descr: '(from Kicad 4.0.7), script generated', tedit 5A19A429)
- `Connector_PinSocket_2.54mm:PinSocket_1x07_P2.54mm_Vertical` — kicad-footprints official library (KiCad-era .pretty, copied verbatim at cdc060f 2026-07-07) (descr: '(from Kicad 4.0.7), script generated', tedit 5A19A429)
- `MountingHole:MountingHole_3.2mm_M3` — kicad-footprints official library (KiCad-era .pretty, copied verbatim at cdc060f 2026-07-07) (official virtual mounting-hole footprint, tedit 56D1B4CB)
- `Package_DIP:DIP-6_W7.62mm_Socket` — kicad-footprints official library (KiCad-era .pretty, copied verbatim at cdc060f 2026-07-07) (canonical official descr, tedit 5A02E8C5)

## LicenseRef-TurnRock-Proprietary

Internal / TurnRock-authored parts. No third-party attribution obligation applies to the entries below.

- `Adafruit:MAX98357A_I2S_1x7_P2.54mm` — authored in-repo 17f9a1e 2026-08-03 from the Adafruit MAX98357A breakout's measured header row
- `Adafruit:MAX98357A_I2S_1x7_P2.54mm_WithTerminals` — authored in-repo 17f9a1e 2026-08-03; speaker terminals as pins 8/9 per owner ruling
- `C_0805` — pcb_worker_seed synthesizer (baae81a 2026-07-18)
- `Connector_PinHeader_2.54mm:PinHeader_1x02_P2.54mm_Vertical` — authored in-repo 17f9a1e 2026-08-03 (tedit 0) (name and descr mirror the official KiCad footprint; dimensions are the generic 2.54mm convention — flagged for release-path attribution review)
- `Diode_SMD:D_SMA` — authored in-repo c90728c 2026-08-03 from the DO-214AC/SMA package convention
- `EVP-ASAC1A:SW_EVP-ASAC1A` — authored in-repo cdc060f 2026-07-07 from the Panasonic EVP-ASAC1A datasheet
- `INMP441:INMP441_I2S_2x3_P2.54mm` — authored in-repo 17f9a1e 2026-08-03 (corrected 7.62mm row spacing)
- `Minerva_Fixture:DAM_MinWeb_2P` — pcb_worker_seed synthesizer, CPN1 coupon fixture (4ca1647 2026-08-08)
- `Minerva_Fixture:FID_Circle_1mm` — pcb_worker_seed synthesizer, CPN1 coupon fixture (4ca1647 2026-08-08)
- `Minerva_Fixture:LOGO_Owl_TestCoupon` — pcb_worker_seed synthesizer, CPN1 coupon fixture (4ca1647 2026-08-08)
- `Minerva_Fixture:SMD_WeirdPads_2P` — pcb_worker_seed synthesizer, CPN1 coupon fixture (4ca1647 2026-08-08)
- `Minerva_Fixture:TP_MinAnnular_0p6` — pcb_worker_seed synthesizer, CPN1 coupon fixture (4ca1647 2026-08-08)
- `Minerva_Fixture:TXT_CouponRev` — pcb_worker_seed synthesizer, CP2 S9 revision text (ad072eb 2026-08-11)
- `R_0805` — pcb_worker_seed synthesizer (baae81a 2026-07-18) (synthetic 0805 land — deliberately NOT the official KiCad R_0805 (comment 599 proof))
- `TH_TestPoint` — pcb_worker_seed synthesizer (baae81a 2026-07-18)

Total entries: 22

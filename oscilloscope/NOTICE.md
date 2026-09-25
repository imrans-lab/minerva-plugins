# Source and attribution

This plugin is GPL-3.0-or-later. The USB commands and voltage/EEPROM layout follow
the published Hantek6022API/OpenHantek documentation and implementation by Robert
Cope, Jochen Hoenicke, Martin Homuth-Rosemann and contributors.

- Hantek6022API firmware: https://github.com/Ho-Ro/Hantek6022API
  pinned e65d52b0f2536e56eaadbb555e5d7b756409c36e; upstream GPL-3.0, with fx2lib
  LGPL-2.1-or-later components. Built with SDCC. Source and notices bundled.
- libusb: https://github.com/libusb/libusb
  pinned 87a55632db62c9bdc58cd31d3ccfa673f1bb017f (1.0.30), LGPL-2.1-or-later;
  dynamically linked; source and license bundled.
- gousb: https://github.com/google/gousb v1.1.3, Apache-2.0;
  license and module source bundled by the packaging process.

The package includes corresponding plugin, libusb and firmware source archives.
Firmware is compiled during packaging; no foreign binary is checked into this repo.

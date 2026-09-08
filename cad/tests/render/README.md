# Render regressions

These tests require a real rendering driver; the headless GDScript suite does
not execute them. They create their own glTF fixture and compare actual pixels
with reference visibility toggled, while leaving cameras and backgrounds fixed.
No model files are checked in.

Use an isolated Minerva checkout with imported resources and built extensions,
next to the plugin checkout. Check that another Godot/Minerva application is not
running before launching. On Linux, for example:

```sh
XDG_DATA_HOME="$(mktemp -d)" xvfb-run -a godot \
  --rendering-method gl_compatibility --path /path/to/Minerva/src \
  --script /path/to/minerva-plugins/cad/tests/render/test_reference_rendering.gd
```

Require exit zero, the expected assertion count, and no script errors. PNGs are
written to the isolated Godot user directory. The test intentionally fails when
no rendering driver is available. Syntax can be checked first using Godot's
`--headless --check-only` flags with the same project/script paths.

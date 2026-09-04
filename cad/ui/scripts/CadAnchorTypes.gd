# CadAnchorTypes.gd — anchor schema constants for the CAD plugin.
# No class_name: off-tree plugin scripts cannot use class_name for cross-script
# type references (see feedback_off_tree_plugin_class_names.md).
# Consumers: preload("scripts/CadAnchorTypes.gd")

## Plugin identifier used in anchor envelopes: { "plugin": PLUGIN, ... }
const PLUGIN: String = "cad"

## Anchor type for a CAD edge: { "plugin": "cad", "type": EDGE_TYPE, "id": N }
const EDGE_TYPE: String = "edge"

## Full anchor key used with register_anchor_resolver / resolve_anchor.
## Format: "<plugin>/<type>" — matches AnnotationHost._anchor_key() output.
const EDGE_ANCHOR_KEY: String = "cad/edge"

## Anchor type for a point on a named node of a reference mesh:
## { "plugin": "cad", "type": POINT_TYPE, "id": "<ref>/<node>@x,y,z",
##   "reference": "<ref>", "node": "<node>", "local": [x, y, z] }
## `local` is the reference file's own frame (converted CAD millimetres, the
## pose NOT applied), so the anchor follows the reference when the document
## re-poses it. See CadPointAnchor.gd for the envelope and its resolver.
const POINT_TYPE: String = "point"

## Full anchor key for a reference-surface point.
const POINT_ANCHOR_KEY: String = "cad/point"

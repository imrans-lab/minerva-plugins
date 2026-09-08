"""Annotation syntax describes the final model; it does not alter geometry."""
import pytest
from mcad_worker import methods


def evaluate(source):
    return methods._evaluate({"source": source, "summary": True})


def test_structured_annotation_retains_nominal_and_optional_limits():
    source = 'part=cube(10)\nannotate [2,3,4], id="hole", dimension="diameter", nominal=4, tolerance=[0,0.2]\n'
    reply = evaluate(source)
    assert reply["ok"], reply
    record = reply["result"]["annotations"][0]
    assert record == {"id": "hole", "at_mm": [2.,3.,4.], "text": "", "source_line": 2,
                      "coordinate_frame": "model", "association": "coordinate_only",
                      "dimension": "diameter", "nominal_mm": 4., "deviations_mm": [0.,0.2]}
    unspecified = evaluate(source.replace(', tolerance=[0,0.2]', ''))
    assert "deviations_mm" not in unspecified["result"]["annotations"][0]
    assert reply["result"]["bbox"] == evaluate('part=cube(10)\n')["result"]["bbox"]


def test_reference_only_annotations_and_repeated_builds():
    source = 'component=mesh("example.glb")\nannotate [1,2,3], text="Reference point"\n'
    a, b = evaluate(source), evaluate(source)
    assert a["ok"] and b["ok"]
    assert a["result"]["body_count"] == 0
    assert a["result"]["annotations"] == b["result"]["annotations"]
    assert len(a["result"]["annotations"]) == 1


@pytest.mark.parametrize("declaration", [
    'annotate [1,2], text="bad"',
    'annotate [1,2,3], nominal=4',
    'annotate [1,2,3], dimension="diameter", nominal=4, tolerance=[0.2,0]',
    'annotate [1,2,3], dimension="diameter", nominal=4, tolerance=[-5,0]',
    'annotate [1,2,3], tolerance=[0,0.2]',
    'annotate [1,2,3], text="bad", unknown=2',
    'annotate [1,2,3], text="one", id="same"\nannotate [4,5,6], text="two", id="same"',
])
def test_invalid_annotation_fails_the_build(declaration):
    result = evaluate('part=cube(10)\n'+declaration+'\n')
    assert not result["ok"]
    assert result["error"]["kind"] == "translate"


def test_export_discloses_overlay_records_outside_geometry(tmp_path):
    source = 'part=cube(10)\nannotate [2,3,4], text="Inspection point"\n'
    reply = methods._export({"source": source, "format": "stl", "path": str(tmp_path / "part.stl")})
    assert reply["ok"], reply
    assert reply["result"]["annotations"] == {
        "included_in_geometry": False, "records": evaluate(source)["result"]["annotations"]}

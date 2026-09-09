"""Motion checks must prove intervals, not infer safety from sparse samples."""
import pytest
from mcad_worker import methods

SOURCE = '''body=cube(1)
a=instance(body,id="moving")
b=translate([5,0,0],instance(body,id="obstacle"))
scene=assembly([a,b])
exploded=configuration(scene,[])
scene
'''


def check(**kwargs):
    reply = methods.handle_request({"id": "motion-test", "method": "motion", "params": {
        "source": SOURCE, "selection": "instance:moving", "against": ["instance:obstacle"],
        "path_mm": [[0,0,0],[10,0,0]], **kwargs}})
    assert reply["ok"], reply
    return reply["result"]


def test_sparse_endpoints_cannot_pass_through_an_obstacle():
    result = check()
    assert result["verdict"] == "fail"
    assert result["violations"][0]["overlap"] is True
    assert result["samples"] > 2
    capped = check(max_samples=2)
    assert capped["verdict"] == "unknown" and capped["pass"] is None
    assert capped["unmeasured_intervals"]


def test_declared_detour_is_certified_and_repeatable():
    params = {"path_mm": [[0,0,0],[0,5,0],[10,5,0],[10,0,0]], "required_mm": .5}
    first, second = check(**params), check(**params)
    assert first == second
    assert first["verdict"] == "pass"
    assert first["certified_clearance_lower_bound_mm"] >= .5


def test_containment_is_overlap_even_without_intersecting_surfaces():
    source = SOURCE.replace('translate([5,0,0],instance(body,id="obstacle"))',
        'translate([-4,-4,-4],instance(cube(10),id="obstacle"))')
    assert check(source=source)["verdict"] == "fail"


def test_presentation_and_unsupported_inputs_cannot_pass():
    assert check(configuration="exploded")["checked"] is False
    for extra in ({"rotation": [0,0,90]}, {"max_samples": True}, {"against": []}):
        reply = methods.handle_request({"id":"unsupported", "method":"motion", "params":{
            "source":SOURCE, "selection":"instance:moving", "against":["instance:obstacle"],
            "path_mm":[[0,0,0],[1,0,0]], **extra}})
        assert not reply["ok"]


def test_mixed_group_and_nested_presentation_cannot_gain_physical_pass():
    mixed = SOURCE.replace('scene=assembly([a,b])', 'ref=mesh("fixture.glb",units="mm",up="z")\nscene=assembly([a,b,instance(ref,id="reference")])')
    reply = methods.handle_request({"id":"mixed", "method":"motion", "params":{
        "source": mixed, "selection":"binding:scene", "against":["instance:obstacle"],
        "path_mm":[[0,0,0],[0,10,0]]}})
    assert not reply["ok"] and "mesh" in reply["error"]["message"]
    nested = SOURCE + 'instance(exploded,id="presentation")\n'
    reply = methods._evaluate({"source":nested, "summary":True})
    assert reply["ok"] and reply["result"]["model"]["physical"] is False

"""Generic mechanical assembly: one definition, touching placed instances, two views."""
import pytest
from mcad_worker import methods

SOURCE = '''block=cube(2)
a=instance(block,id="left",source="measured fixture",accuracy="measured")
b=translate([2,0,0],instance(block,id="right",source="measured fixture",accuracy="measured"))
assembled=assembly([a,b])
exploded=configuration(assembled,[translate([10,0,0],b)])
partial=configuration(assembled,[],include=["left"],physical=true)
assembled
'''


def result(**kwargs):
    reply = methods._evaluate({"source": SOURCE, "summary": True, **kwargs})
    assert reply["ok"], reply
    return reply["result"]


def test_touching_instances_share_definition_and_keep_separate_bodies():
    model = result()
    assert model["body_count"] == 2  # Boolean fusion would produce one body.
    assert model["bbox"]["max"] == [4,2,2]
    assert len(model["model"]["definitions"]) == 1
    assert [i["id"] for i in model["model"]["instances"]] == ["left", "right"]
    assert model["model"]["definitions"][0]["accuracy"] == "measured"


def test_selection_and_configuration_reuse_one_compilation(monkeypatch, tmp_path):
    methods.reset_caches()
    canonical = result()
    import mcad.evaluator as evaluator
    monkeypatch.setattr(evaluator, "translate_program", lambda *_: pytest.fail("unexpected recompilation"))
    selected = result(selection="instance:right")
    assert selected["bbox"]["min"] == [2,0,0]
    assert result(configuration="exploded")["bbox"]["max"] == [14,2,2]
    assert result(configuration="partial")["body_count"] == 1
    assert result() == canonical
    exported = methods._export({"source": SOURCE, "selection": "instance:right",
        "configuration": "exploded", "format": "step", "path": str(tmp_path / "right.step")})
    assert exported["ok"], exported
    from build123d import import_step
    shape = import_step(str(tmp_path / "right.step"))
    assert shape.bounding_box().min.X == pytest.approx(12)
    assert shape.volume == pytest.approx(8)


def test_reference_only_nested_assembly_retains_world_pose():
    source = '''ref=mesh("module.glb",units="mm",up="z")
unit=assembly([instance(ref,id="board")])
whole=assembly([translate([10,20,30],instance(unit,id="module"))])
'''
    reply = methods._evaluate({"source": source})
    assert reply["ok"], reply
    assert reply["result"]["body_count"] == 0
    assert len(reply["result"]["references"]) == 1
    ref = reply["result"]["references"][0]
    assert ref["name"] == "module/board"
    assert [row[3] for row in ref["matrix"][:3]] == [10,20,30]


@pytest.mark.parametrize("suffix", [
    'bad=assembly([a,a])',
    'bad=configuration(assembled,[instance(block,id="absent")])',
    'bad=configuration(assembled,[instance(cube(3),id="left")])',
    'bad=instance(2,id="number")',
])
def test_invalid_assembly_does_not_silently_drop_objects(suffix):
    reply = methods._evaluate({"source": SOURCE.rsplit("assembled\n",1)[0]+suffix+'\n'})
    assert not reply["ok"]
    assert reply["error"]["kind"] == "translate"


def test_missing_and_ambiguous_selections_are_explicit():
    source = SOURCE.replace('assembled\n', 'assembled\n',1).replace('a=instance', 'left=cube(3)\na=instance',1)
    for selection, word in [('absent','unknown'),('left','ambiguous')]:
        reply = methods._evaluate({"source": source, "selection": selection})
        assert not reply["ok"] and word in reply["error"]["message"]
    assert methods._evaluate({"source":source,"selection":"instance:left"})["ok"]


def test_module_local_names_do_not_merge_different_definitions():
    source = '''module post(size, name):
    shape=cube(size)
    return instance(shape,id=name)
scene=assembly([post(2,"first"),post(3,"second")])
'''
    reply = methods._evaluate({"source":source,"summary":True})
    assert reply["ok"], reply
    assert len(reply["result"]["model"]["definitions"]) == 2
    assert reply["result"]["body_count"] == 2


def test_binding_selection_preserves_presentation_configuration_eligibility():
    reply = methods._evaluate({"source": SOURCE, "selection": "binding:block", "configuration": "exploded"})
    assert reply["ok"], reply
    assert reply["result"]["model"]["configuration"] == "exploded"
    assert reply["result"]["model"]["physical"] is False


def test_nested_group_selection_keeps_world_placement_and_members():
    source = '''piece=cube(2)
sub=assembly([instance(piece,id="one"),translate([4,0,0],instance(piece,id="two"))])
scene=assembly([translate([30,0,0],instance(sub,id="rack"))])
'''
    reply = methods._evaluate({"source": source, "selection": "instance:rack", "summary": True})
    assert reply["ok"], reply
    result = reply["result"]
    assert result["bbox"]["min"] == [30, 0, 0]
    assert result["bbox"]["max"] == [36, 2, 2]
    assert result["body_count"] == 2
    assert result["model"]["groups"] == [{"id": "rack", "instances": ["rack/one", "rack/two"]}]

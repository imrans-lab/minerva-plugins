import pytest
from mcad.evaluator import evaluate_source


def test_parallel_fillet_and_planar_outer_chamfer_on_generic_parts():
    rounded = evaluate_source('part=scale([20,20,5],cube(1))\nfillet part, edges(part, parallel=[0,0,1], expected=4), r=1\n')
    assert 1900 < rounded.shape.volume < 2000
    plate = '''part=scale([20,20,5],cube(1))-translate([10,10,0],cylinder(h=5,r=3))
chamfer part, edges(part, face_normal=[0,0,1], outer=true, expected=4), d=0.5
'''
    result = evaluate_source(plate)
    assert result.shape.is_valid
    assert len(result.shape.solids()) == 1


def test_height_rule_rounds_loft_rim_without_edge_numbers():
    source = '''body = loft:
    z=0: rect(20,20)
    z=10: rect(16,16)
fillet body, edges(body, above_z=10, expected=4), r=0.5
'''
    result = evaluate_source(source)
    assert result.shape.is_valid
    assert result.shape.volume > 2500


@pytest.mark.parametrize('tail,reason', [
    ('fillet part, edges(part, above_z=30), r=1', 'matched no edges'),
    ('fillet part, edges(part, parallel=[0,0,1], expected=3), r=1', 'matched 4'),
    ('chosen=edges(part,parallel=[0,0,1])\npart=translate([1,0,0],part)\nfillet part, chosen, r=1', 'superseded'),
    ('fillet part, edges(part,outer=true), r=1', 'requires face_normal'),
])
def test_rules_refuse_missing_mismatched_or_stale_geometry(tail, reason):
    with pytest.raises(Exception, match=reason):
        evaluate_source('part=scale([20,20,5],cube(1))\n'+tail+'\n')

"""Picking identities and precise source spans survive ordinary CAD edits."""
from mcad.evaluator import evaluate_source

SOURCE = '''# Preserve formatting and comments.
block = cube(12)
left = instance(block, id="left", definition="block")
right = translate([25,0,0], instance(block, id="right", definition="block")) # trailing
assembled = assembly([left,right])
exploded = configuration(assembled, [translate([0,0,20],right)], physical=false)
assembled
'''

def test_shared_definition_picking_and_targeted_source_edit():
    before = evaluate_source(SOURCE)
    assert list(before.picking) == ['block']
    placement = before.model['placements']['right']
    expression = placement['expression']
    assert expression.startswith('translate(') and expression.endswith('))')
    assert SOURCE[placement['start']:placement['end']] == expression
    after_source = SOURCE[:placement['start']] + f'translate([3,0,0], {expression})' + SOURCE[placement['end']:]
    assert '# trailing\n' in after_source
    after = evaluate_source(after_source)
    assert [i['matrix'][0][3] for i in after.model['instances']] == [0,28]
    assert before.model['instances'][1]['matrix'][0][3] == 25
    assert before.picking == after.picking


def test_configuration_and_generated_instances_are_not_misidentified():
    exploded = evaluate_source(SOURCE, configuration='exploded')
    assert 'right' not in exploded.model['placements']
    generated = evaluate_source('''module part(id):
    return instance(cube(12), id=id, definition="block")
x = part("x")
x
''')
    assert generated.model['placements'] == {}


def test_multiline_unicode_source_and_reference_placement():
    source = '# µ stays intact\nref = translate(\n    [1,2,3], mesh("part.glb")) # ref\n'
    result = evaluate_source(source)
    span = result.model['placements']['ref']
    assert source[span['start']:span['end']] == 'translate(\n    [1,2,3], mesh("part.glb"))'
    assert result.references[0]['matrix'][0][3] == 1

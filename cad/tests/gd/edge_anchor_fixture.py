import json
import math
import os
import sys
from pathlib import Path
from typing import Any

# Tests run from the host project; resolve the worker beside this fixture.
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "worker"))
from mcad_worker.methods import handle_request


def evaluate(source: str) -> dict[str, Any]:
    response = handle_request({'id': 'anchor-fixture', 'method': 'evaluate', 'params': {'source': source}})
    assert response['ok'], response
    return response['result']


def same(left: dict[str, Any], right: dict[str, Any]) -> bool:
    return (left['kind'] == right['kind']
            and math.dist(left['midpoint'], right['midpoint']) < 1e-7
            and abs(left['length'] - right['length']) < 1e-7
            and left['radius'] == right['radius'])


source = 'part = cube(10, center=true)\n'
before = evaluate(source)
after = evaluate(source + 'chamfer part, 1, d=1\n')
pairs = [(a, b) for a in before['edges'] for b in after['edges'] if same(a, b) and a['id'] != b['id']]
assert pairs, 'fixture must renumber a geometrically surviving edge'
consumed = [a for a in before['edges'] if not any(same(a, b) for b in after['edges'])]
assert consumed, 'fixture must consume an edge'
circle = evaluate('part = cylinder(r=3, h=10)\n')
circle_edge = next(edge for edge in circle['edges'] if edge['kind'] == 'circle')
fixture = {'before': before['edges'], 'after': after['edges'], 'survivor': pairs[0][0],
           'survivor_after': pairs[0][1], 'consumed': consumed[0], 'mesh': after['mesh'],
           'circle': circle['edges'], 'circle_edge': circle_edge}
Path(os.environ['CAD_ANCHOR_FIXTURE']).write_text(json.dumps(fixture))
print('REAL_GEOMETRY', 'survivor', pairs[0][0]['id'], '->', pairs[0][1]['id'],
      'consumed', consumed[0]['id'], 'circle', circle_edge['id'])

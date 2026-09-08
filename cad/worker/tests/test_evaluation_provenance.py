"""Cached geometry must identify its source and tessellation settings."""
from mcad_worker import methods


def test_mesh_cache_respects_tessellation_settings():
    methods.reset_caches()
    source = "part = sphere(r=10)\n"
    coarse = methods._evaluate({"source": source, "tolerance": 1.0, "angular_tolerance": 0.5})
    fine = methods._evaluate({"source": source, "tolerance": 0.01, "angular_tolerance": 0.05})
    assert coarse["ok"] and fine["ok"]
    assert len(fine["result"]["mesh"]["faces"]) > len(coarse["result"]["mesh"]["faces"])
    assert fine["result"]["provenance"]["source_digest"] == methods._digest(source)
    assert fine["result"]["provenance"]["settings"] == {"tolerance": 0.01, "angular_tolerance": 0.05}
    summary = methods._evaluate({"source": source, "tolerance": 0.01, "angular_tolerance": 0.05, "summary": True})
    assert summary["result"]["provenance"] == fine["result"]["provenance"]
    methods.reset_caches()

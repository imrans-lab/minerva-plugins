"""The release manifest contract shared by packaging and post-publication checks."""
from collections.abc import Mapping


def verify_packed_manifest(source: Mapping[str, object], packed: Mapping[str, object]) -> None:
    """Accept exactly the tagged source manifest with its setup field removed."""
    expected = {key: value for key, value in source.items() if key != "setup"}
    if packed != expected:
        raise ValueError("packed manifest differs from source minus setup")

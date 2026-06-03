"""Shared test fixtures for the Code Tools worker test suite.

Provides `build_codetools_fixture(cls, prefix)` — a common setUpClass helper
that creates a temp directory with a small on-disk file tree suitable for
testing glob, grep, and bash tools. Import and call from setUpClass:

    from conftest import build_codetools_fixture
    class MyTest(unittest.TestCase):
        @classmethod
        def setUpClass(cls):
            build_codetools_fixture(cls, "my_prefix_")

After the call, `cls` will have:
    cls._tmp       — Path: root of the temporary tree
    cls.fixture_dir — Path: root populated with test files

The SQLite-based fixture used by code-visualizer tests lives in their own
classes (CodeVisualizerFunctionalTest, GetGraphTest) and is NOT managed here
to keep each fixture self-contained.

P4 DRY note: the `setUpClass` in test_code_visualizer_functional.py and
test_get_graph.py still run their own SQLite setup because they depend on
tree-sitter and the code-visualizer indexer. Extracting them here would couple
conftest.py to that optional dependency. The file-primitive tests use this
lighter fixture only.
"""

from __future__ import annotations

import os
import shutil
import tempfile
from pathlib import Path


def build_codetools_fixture(cls, prefix: str = "codetools_files_") -> None:
    """Populate `cls._tmp` and `cls.fixture_dir` with a small test file tree.

    Tree layout:

        <tmp>/
          fixture/
            src/
              main.py       — contains 'def main()' and 'hello world'
              utils.py      — contains 'def helper()' and 'TODO: fix me'
            tests/
              test_main.py  — contains 'import main' and 'assert True'
            data/
              sample.txt    — plain text, contains 'needle'
              binary.bin    — binary file (null bytes)
            .git/
              config        — should be excluded from glob/grep results
            node_modules/
              pkg/
                index.js    — should be excluded from glob/grep results
    """
    tmp = Path(tempfile.mkdtemp(prefix=prefix))
    cls._tmp = tmp

    fixture = tmp / "fixture"
    cls.fixture_dir = fixture

    # src/
    (fixture / "src").mkdir(parents=True)
    (fixture / "src" / "main.py").write_text(
        "def main():\n    print('hello world')\n", encoding="utf-8"
    )
    (fixture / "src" / "utils.py").write_text(
        "def helper(x):\n    # TODO: fix me\n    return x\n", encoding="utf-8"
    )

    # tests/
    (fixture / "tests").mkdir()
    (fixture / "tests" / "test_main.py").write_text(
        "import main\ndef test_it():\n    assert True\n", encoding="utf-8"
    )

    # data/
    (fixture / "data").mkdir()
    (fixture / "data" / "sample.txt").write_text(
        "this file contains the needle\n", encoding="utf-8"
    )
    (fixture / "data" / "binary.bin").write_bytes(
        b"some data\x00more data\x00binary content"
    )

    # Noise dirs — must be excluded by glob/grep.
    (fixture / ".git").mkdir()
    (fixture / ".git" / "config").write_text("[core]\n    bare = false\n")
    (fixture / "node_modules" / "pkg").mkdir(parents=True)
    (fixture / "node_modules" / "pkg" / "index.js").write_text(
        "module.exports = {};\n"
    )

    cls._tmp_cleanup = tmp


def teardown_codetools_fixture(cls) -> None:
    """Remove the temporary tree. Call from tearDownClass."""
    shutil.rmtree(cls._tmp, ignore_errors=True)

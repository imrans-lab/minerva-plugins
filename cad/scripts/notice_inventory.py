"""The cad runtime bundle's licence inventory — the data the NOTICE renders.

WHY THIS IS A MODULE OF ITS OWN. ``gen_notice.py`` is the gate: it reads the
lock, the census and this inventory, refuses on any disagreement, and renders
``cad/NOTICE.md``. This file is the inventory it checks — one entry per thing
that ships. Keeping the two apart means the gate's logic stays readable while
the data grows with the dependency tree.

WHAT AN ENTRY IS FOR, AND WHY IT IS NOT AUTOMATIC. Two different blind spots
make a generated-from-metadata inventory wrong:

* a wheel vendors other projects. python-fcl's wheel contains compiled FCL,
  libccd, OctoMap and Eigen but ships only python-fcl's LICENSE; cadquery-ocp's
  wheel contains the whole of OCCT as shared libraries and ships no licence
  text at all. Nothing in the dist-info can tell you that.
* a wheel ships a licence text under any of a dozen filenames, or none. The
  text in the inventory is taken from the installed dist-info where the wheel
  ships one and from the upstream project's tagged source where it does not;
  the per-entry note says which.

The licence texts live in ``cad/licenses/runtime/`` and are copied into the
bundle and the release tarball, because binary redistribution under BSD/MIT
requires the notice, the conditions and the disclaimer to travel "in the
documentation and/or other materials provided with the distribution" — a
NOTICE that only names a licence does not satisfy that.
"""

from __future__ import annotations

from typing import NamedTuple, Optional


#: Licences we are willing to ship inside a binary distribution without an
#: extra obligation beyond carrying the text. Anything not here and not in
#: :data:`SOURCE_OBLIGATION_LICENCES` is a refusal, not a warning — an
#: unrecognised licence is refused rather than guessed at.
PERMISSIVE_LICENCES = frozenset({
    "BSD-2-Clause",
    "BSD-3-Clause",
    "MIT",
    "ISC",
    "HPND",
    "Apache-2.0",
    "PSF-2.0",
    "Apache-2.0 OR BSD-2-Clause",
    "Apache-2.0 AND BSD-3-Clause",
    "LicenseRef-Matplotlib-PSF",
    "LicenseRef-Microsoft-VC-Redistributable",
})

#: Licences that ship only because a further obligation is discharged in the
#: NOTICE itself, mapped to what that obligation is. An entry carrying one of
#: these MUST fill in ``obligation``; the gate refuses an empty one, because
#: the text alone does not satisfy either licence.
#:
#: This is the only door LGPL code comes through. It is not "LGPL is fine": it
#: is "this specific dynamically-linked library, whose source we point at and
#: whose relinking procedure we spell out". A GPL licence, or an LGPL entry
#: whose statement is missing, still refuses.
SOURCE_OBLIGATION_LICENCES = {
    "MPL-2.0":
        "MPL 2.0 section 3.2(a) — recipients must be told where the source "
        "for the covered files is.",
    "LGPL-2.1-only WITH OCCT-exception-1.0":
        "LGPL 2.1 section 6 — a dynamically linked library must be "
        "accompanied by its complete corresponding source and by terms that "
        "permit the recipient to modify it and relink.",
}

#: Every licence an entry may carry.
ALLOWED_LICENCES = PERMISSIVE_LICENCES | frozenset(SOURCE_OBLIGATION_LICENCES)


#: Files under ``cad/licenses/`` that are NOT a component's licence text but
#: still ship with the distribution, declared so the tree check can demand
#: them by name.
#:
#: With only the licence texts declared, moving ``cad/licenses/README.md``
#: away leaves the gate reporting "up to date". The inventory — not a
#: directory listing — decides what must be present, so anything the directory
#: ships has to be named somewhere.
DECLARED_SUPPORT_FILES = {
    "README.md": "explains what the directory is, how it reaches the "
                 "distribution, and what to do when adding a dependency",
}


#: Census distributions that are deliberately NOT inventoried, each mapped to
#: the reason. Empty today; the mechanism exists so that a distribution which
#: genuinely needs no attribution entry (a first-party package, say) can be
#: dismissed by name and with a reason a reader can argue with, rather than by
#: silence. It is NOT a place to park work: a distribution whose licence has
#: simply not been looked at yet fails the gate.
DISTRIBUTION_EXCLUSIONS: dict = {}


class RuntimeComponent(NamedTuple):
    """One third-party component that ships inside the runtime bundle.

    ``distribution`` is the census entry it arrives through (the join back to
    ``runtime-bundle.manifest``), or ``None`` for something that enters the
    bundle by another route — the C++ runtime DLLs the Windows wheel repair
    copies in are not a PyPI package at all. ``component`` is what the thing
    actually is: python-fcl's wheel yields five entries sharing one
    distribution, and cadquery-ocp's yields two.

    ``version`` is the component's own version. Where it equals the
    distribution's, the gate cross-checks it against the census, so a
    transitive upgrade cannot leave a stale version in the NOTICE.

    ``license_files`` are names inside ``cad/licenses/runtime/``. More than
    one is normal — a dual licence ships both texts, and an Apache-2.0
    project's NOTICE travels with its LICENSE.

    ``obligation`` is the statement a licence in
    :data:`SOURCE_OBLIGATION_LICENCES` requires beyond the text itself; empty
    for everything else.
    """

    distribution: Optional[str]
    component: str
    version: str
    license: str
    copyright: str
    source_url: str
    license_files: tuple
    note: str
    obligation: str = ""


#: Every third-party component inside the bundle, in render order: the
#: python-fcl tree and the Windows C++ runtime first, then one entry per
#: census distribution in name order, with OCCT following the cadquery-ocp
#: wheel it arrives inside.
#:
#: The four components under the ``python-fcl`` distribution are what its wheel
#: vendors, verified by unzipping the wheels for all four release targets: the
#: linux wheel carries ``python_fcl.libs/`` (libfcl, libccd, liboctomap,
#: liboctomath), the macOS wheels carry the same set under ``fcl/.dylibs/``,
#: and the Windows wheel links FCL into the .pyd and ships ccd.dll, octomap.dll
#: and octomath.dll beside it. Eigen is header-only and leaves no file behind —
#: it is compiled INTO libfcl, which is exactly why a file-based inventory
#: cannot find it and this list is maintained by hand.
RUNTIME_COMPONENTS: tuple = (
    RuntimeComponent(
        distribution="python-fcl",
        component="python-fcl",
        version="0.7.0.11",
        license="BSD-3-Clause",
        copyright="Copyright (c) 2017, Matthew Matl",
        source_url="https://github.com/BerkeleyAutomation/python-fcl",
        license_files=("python-fcl-0.7.0.11.LICENSE.txt",),
        note="Cython bindings to FCL. The only licence the wheel itself "
             "ships; the four components below are compiled into it.",
    ),
    RuntimeComponent(
        distribution="python-fcl",
        component="FCL (Flexible Collision Library)",
        version="0.7.0",
        license="BSD-3-Clause",
        copyright="Copyright (c) 2008-2014, Willow Garage, Inc.; "
                  "Copyright (c) 2014-2016, Open Source Robotics Foundation",
        source_url="https://github.com/flexible-collision-library/fcl/tree/0.7.0",
        license_files=("fcl-0.7.0.LICENSE.txt",),
        note="Built by python-fcl from the ambi-robotics/fcl fork pinned at "
             "FCL 0.7.0. Ships as libfcl (linux/macOS) or linked into "
             "fcl.cp312-win_amd64.pyd (Windows).",
    ),
    RuntimeComponent(
        distribution="python-fcl",
        component="libccd",
        version="2.1",
        license="BSD-3-Clause",
        copyright="Copyright (c) 2010-2012 Daniel Fiser <danfis@danfis.cz>, "
                  "Intelligent and Mobile Robotics Group, Czech Technical "
                  "University in Prague",
        source_url="https://github.com/danfis/libccd/tree/v2.1",
        license_files=("libccd-2.1.BSD-LICENSE.txt",),
        note="FCL's convex-collision backend. Ships as libccd / ccd.dll.",
    ),
    RuntimeComponent(
        distribution="python-fcl",
        component="OctoMap (octomap + octomath)",
        version="1.9.8",
        license="BSD-3-Clause",
        copyright="Copyright (c) 2009-2013, K.M. Wurm and A. Hornung, "
                  "University of Freiburg",
        source_url="https://github.com/OctoMap/octomap/tree/v1.9.8",
        license_files=("octomap-1.9.8.LICENSE.txt",),
        note="FCL's octree collision geometry. Only the New-BSD octomap and "
             "octomath libraries are in the wheel — octovis, the GPL viewer "
             "in the same upstream repository, is not.",
    ),
    RuntimeComponent(
        distribution="python-fcl",
        component="Eigen",
        version="3.3.9",
        license="MPL-2.0",
        copyright="Copyright (c) the Eigen authors "
                  "(see the upstream source for per-file notices)",
        source_url="https://gitlab.com/libeigen/eigen/-/archive/3.3.9/eigen-3.3.9.tar.gz",
        license_files=("eigen-3.3.9.COPYING.MPL2.txt",
                       "eigen-3.3.9.COPYING.README.txt"),
        note="Header-only, compiled unmodified into libfcl, so no Eigen file "
             "appears in the bundle. FCL 0.7.0 includes only <Eigen/Core>, "
             "<Eigen/Dense> and <Eigen/StdVector>; Eigen's two LGPL-2.1 files "
             "(IterativeLinearSolvers/IncompleteLUT.h, "
             "SparseCholesky/SimplicialCholesky_impl.h) are sparse-solver "
             "headers FCL never includes, so no LGPL code is compiled in. "
             "Re-check this on any Eigen or FCL version bump.",
        obligation="Eigen 3.3.9's MPL-2.0 source is at "
                   "https://gitlab.com/libeigen/eigen/-/archive/3.3.9/"
                   "eigen-3.3.9.tar.gz. The covered files are unmodified "
                   "upstream headers compiled into libfcl, so a recipient "
                   "who wants a modified Eigen rebuilds python-fcl from its "
                   "own source against that archive; nothing in this bundle "
                   "carries Eigen source of its own.",
    ),
    RuntimeComponent(
        distribution=None,
        component="Microsoft Visual C++ runtime (MSVCP140.dll and the "
                  "VCRUNTIME140 pair)",
        version="Visual Studio 2022 redistributable",
        license="LicenseRef-Microsoft-VC-Redistributable",
        copyright="Copyright (c) Microsoft Corporation",
        source_url="https://learn.microsoft.com/en-us/visualstudio/releases/2022/redistribution",
        license_files=("microsoft-vc-runtime.ATTRIBUTION.txt",),
        note="Windows bundle only. The python-fcl extension imports "
             "MSVCP140.dll, which python-build-standalone does not ship, so "
             "the Windows build repairs the wheel with delvewheel and the DLL "
             "travels inside the bundle instead of being resolved from the "
             "user's machine. Nothing is checked into this repository.",
    ),
    RuntimeComponent(
        distribution='anytree',
        component='anytree',
        version='2.13.0',
        license='Apache-2.0',
        copyright='Copyright (c) 2016 c0fec0de',
        source_url='https://github.com/c0fec0de/anytree',
        license_files=('anytree-2.13.0.LICENSE.txt',),
        note='Tree data structure used by build123d to model assembly '
             'hierarchies.',
    ),
    RuntimeComponent(
        distribution='asttokens',
        component='asttokens',
        version='3.0.2',
        license='Apache-2.0',
        copyright='Copyright (c) 2016, Grist Labs, Inc.',
        source_url='https://github.com/gristlabs/asttokens',
        license_files=('asttokens-3.0.2.LICENSE.txt',),
        note='Pulled in by stack-data, which IPython uses for tracebacks.',
    ),
    RuntimeComponent(
        distribution='build123d',
        component='build123d',
        version='0.10.0',
        license='Apache-2.0',
        copyright='Copyright 2022 Roger Maitland',
        source_url='https://github.com/gumyr/build123d',
        license_files=('build123d-0.10.0.LICENSE.txt',
                        'build123d-0.10.0.NOTICE.txt'),
        note='The modelling API the cad worker is written against — the '
             'reason the bundle exists. Its wheel ships an Apache-2.0 '
             'NOTICE, which section 4(d) requires to travel with any '
             'distribution, so both texts are inventoried.',
    ),
    RuntimeComponent(
        distribution='cadquery-ocp',
        component='cadquery-ocp',
        version='7.8.1.1.post1',
        license='Apache-2.0',
        copyright='Copyright (c) the OCP authors',
        source_url='https://github.com/CadQuery/OCP',
        license_files=('cadquery-ocp-7.8.1.1.post1.OCP-LICENSE.txt',),
        note='pybind11 bindings to Open CASCADE Technology. The wheel ships '
             'NO licence text of its own, so the Apache-2.0 text here is '
             'taken from the OCP repository. The wheel also vendors OCCT '
             'itself as shared libraries — see the OCCT entry below, and '
             'note the wheel additionally vendors ~22 unrelated native '
             'libraries whose licences are NOT covered by this inventory.',
    ),
    RuntimeComponent(
        distribution='cadquery-ocp',
        component='Open CASCADE Technology (OCCT)',
        version='7.8.1',
        license='LGPL-2.1-only WITH OCCT-exception-1.0',
        copyright='Copyright (c) 1999-2024 OPEN CASCADE SAS',
        source_url='https://github.com/Open-Cascade-SAS/OCCT/tree/V7_8_1',
        license_files=('occt-7.8.1.LICENSE_LGPL_21.txt',
                        'occt-7.8.1.OCCT_LGPL_EXCEPTION.txt'),
        note='The geometry kernel every modelling operation in the cad '
             'worker ends up in. It reaches the bundle inside the '
             'cadquery-ocp wheel rather than as a distribution of its own, '
             'so no dist-info names it and a census of site-packages cannot '
             "find it — the same blind spot as python-fcl's vendored tree. "
             'Version read off the vendored sonames (libTK*.so.7.8.1) and '
             "confirmed by cadquery-ocp's own 7.8.1.x version line.",
        obligation='OCCT is DYNAMICALLY LINKED, not compiled in: the cadquery-ocp '
                   'wheel ships OCCT as separate shared libraries '
                   '(site-packages/cadquery_ocp.libs/libTK*.so.7.8.1 on linux, the '
                   'matching .dylib set on macOS, TK*.dll beside the OCP extension '
                   'on windows), and the OCP extension resolves them through the '
                   'dynamic loader at import time. Under LGPL-2.1 section 6 that '
                   'means a recipient must be able to modify OCCT and relink. '
                   'Complete corresponding source for OCCT 7.8.1 is at '
                   'https://github.com/Open-Cascade-SAS/OCCT/tree/V7_8_1 (also '
                   'released by Open CASCADE SAS at '
                   'https://dev.opencascade.org/release). To relink: extract the '
                   'runtime bundle, build OCCT 7.8.1 (or a modified OCCT) with the '
                   'same soname, and replace the corresponding files in '
                   'cadquery_ocp.libs/ — the cad plugin binary itself needs no '
                   'rebuild, because nothing in it links OCCT statically. The Open '
                   'CASCADE exception additionally permits the object code of a '
                   'work that uses the library to incorporate material from OCCT '
                   'header files.',
    ),
    RuntimeComponent(
        distribution='cadquery-ocp-proxy',
        component='cadquery-ocp-proxy',
        version='7.9.3.1.1',
        license='Apache-2.0',
        copyright='Copyright (c) Bernhard Walter',
        source_url='https://pypi.org/project/cadquery-ocp-proxy/',
        license_files=('cadquery-ocp-proxy-7.9.3.1.1.LICENSE.txt',),
        note='A no-op package (an __init__.py and a _version.py) whose only '
             'job is to pin which cadquery-ocp variant resolves. Its wheel '
             'ships no licence text and its repository is not public, so the '
             'canonical Apache-2.0 text is used, matching the Apache-2.0 its '
             'METADATA declares.',
    ),
    RuntimeComponent(
        distribution='contourpy',
        component='contourpy',
        version='1.3.3',
        license='BSD-3-Clause',
        copyright='Copyright (c) 2021-2025, ContourPy Developers.',
        source_url='https://github.com/contourpy/contourpy',
        license_files=('contourpy-1.3.3.LICENSE.txt',),
        note="matplotlib's contour engine.",
    ),
    RuntimeComponent(
        distribution='cycler',
        component='cycler',
        version='0.12.1',
        license='BSD-3-Clause',
        copyright='Copyright (c) 2015, matplotlib project',
        source_url='https://github.com/matplotlib/cycler',
        license_files=('cycler-0.12.1.LICENSE.txt',),
        note='matplotlib dependency.',
    ),
    RuntimeComponent(
        distribution='executing',
        component='executing',
        version='2.2.1',
        license='MIT',
        copyright='Copyright (c) 2019 Alex Hall',
        source_url='https://github.com/alexmojaki/executing',
        license_files=('executing-2.2.1.LICENSE.txt',),
        note='stack-data dependency.',
    ),
    RuntimeComponent(
        distribution='ezdxf',
        component='ezdxf',
        version='1.4.4',
        license='MIT',
        copyright='Copyright (c) 2020 Manfred Moitzi',
        source_url='https://github.com/mozman/ezdxf',
        license_files=('ezdxf-1.4.4.LICENSE.txt',),
        note='DXF reader/writer build123d uses for 2D import and export.',
    ),
    RuntimeComponent(
        distribution='fonttools',
        component='fonttools',
        version='4.64.0',
        license='MIT',
        copyright='Copyright (c) 2017 Just van Rossum',
        source_url='https://github.com/fonttools/fonttools',
        license_files=('fonttools-4.64.0.LICENSE.external.txt',
                        'fonttools-4.64.0.LICENSE.txt'),
        note="Font parsing for matplotlib and for build123d's text features. "
             'Its LICENSE.external records the terms of the fonts and '
             'third-party code the project carries, and is inventoried '
             'alongside the MIT text.',
    ),
    RuntimeComponent(
        distribution='ipython',
        component='ipython',
        version='9.17.1',
        license='BSD-3-Clause',
        copyright='Copyright (c) 2008-Present, IPython Development Team; '
                  'Copyright (c) 2001-2007, Fernando Perez',
        source_url='https://github.com/ipython/ipython',
        license_files=('ipython-9.17.1.LICENSE.txt',),
        note='Transitive through build123d. Nothing in the cad worker '
             'imports it; it ships because pip resolved it.',
    ),
    RuntimeComponent(
        distribution='ipython-pygments-lexers',
        component='ipython-pygments-lexers',
        version='1.1.1',
        license='BSD-3-Clause',
        copyright='Copyright (c) 2012-Present, IPython Development Team',
        source_url='https://github.com/ipython/ipython-pygments-lexers',
        license_files=('ipython-pygments-lexers-1.1.1.LICENSE.txt',),
        note='IPython dependency.',
    ),
    RuntimeComponent(
        distribution='jedi',
        component='jedi',
        version='0.20.0',
        license='MIT',
        copyright='Copyright (c) <2013> <David Halter and others, see '
                  'AUTHORS.txt>',
        source_url='https://github.com/davidhalter/jedi',
        license_files=('jedi-0.20.0.LICENSE.txt',),
        note='IPython completion dependency.',
    ),
    RuntimeComponent(
        distribution='kiwisolver',
        component='kiwisolver',
        version='1.5.1',
        license='BSD-3-Clause',
        copyright='Copyright (c) 2013-2026, Nucleic Development Team',
        source_url='https://github.com/nucleic/kiwi',
        license_files=('kiwisolver-1.5.1.LICENSE.txt',),
        note="matplotlib's layout solver.",
    ),
    RuntimeComponent(
        distribution='lib3mf',
        component='lib3mf',
        version='2.5.0',
        license='BSD-2-Clause',
        copyright='Copyright (c) 2024, 3MF Consortium',
        source_url='https://github.com/3MFConsortium/lib3mf',
        license_files=('lib3mf-2.5.0.LICENSE.txt',),
        note='3MF read/write. The wheel carries the compiled lib3mf shared '
             'library.',
    ),
    RuntimeComponent(
        distribution='matplotlib',
        component='matplotlib',
        version='3.11.1',
        license='LicenseRef-Matplotlib-PSF',
        copyright='Copyright (c) 2012- Matplotlib Development Team; Copyright (c) '
                  '2002-2011 John D. Hunter',
        source_url='https://github.com/matplotlib/matplotlib',
        license_files=('matplotlib-3.11.1.LICENSE.txt',),
        note="Transitive through build123d's plotting helpers. Its licence "
             'is a PSF-derived agreement of its own rather than an '
             'SPDX-listed one, so it is carried under a LicenseRef id and '
             'its full text is shipped; the terms are permissive '
             '(attribution plus the summary of changes).',
    ),
    RuntimeComponent(
        distribution='matplotlib-inline',
        component='matplotlib-inline',
        version='0.2.2',
        license='BSD-3-Clause',
        copyright='Copyright (c) 2019-2022, IPython Development Team.',
        source_url='https://github.com/ipython/matplotlib-inline',
        license_files=('matplotlib-inline-0.2.2.LICENSE.txt',),
        note='IPython/matplotlib glue.',
    ),
    RuntimeComponent(
        distribution='mpmath',
        component='mpmath',
        version='1.3.0',
        license='BSD-3-Clause',
        copyright='Copyright (c) 2005-2021 Fredrik Johansson and mpmath '
                  'contributors',
        source_url='https://github.com/mpmath/mpmath',
        license_files=('mpmath-1.3.0.LICENSE.txt',),
        note='sympy dependency.',
    ),
    RuntimeComponent(
        distribution='numpy',
        component='numpy',
        version='2.5.2',
        license='BSD-3-Clause',
        copyright='Copyright (c) 2005-2025, NumPy Developers.',
        source_url='https://github.com/numpy/numpy',
        license_files=('numpy-2.5.2.LICENSE.txt',),
        note="Array backbone for the worker's geometry code. The text "
             'inventoried here is not BSD-3-Clause alone: after NumPy\'s own '
             'licence it carries the statements for the shared libraries the '
             'wheel ships in numpy.libs — OpenBLAS and the LAPACK bundled '
             'inside it (both BSD-3-Clause), and libgfortran and libquadmath '
             '(GPL-3.0-or-later under the GCC Runtime Library Exception, '
             'whose full text is included). The wheel ALSO ships per-component '
             'texts under its dist-info for source it vendors (Mersenne '
             'Twister, PCG64, pocketfft, LAPACK-lite, highway, dragon4, '
             'libdivide, x86-simd-sort); those are compiled into _multiarray '
             'and friends rather than shipped as separate files.',
    ),
    RuntimeComponent(
        distribution='ocp-gordon',
        component='ocp-gordon',
        version='0.2.2',
        license='Apache-2.0',
        copyright='Copyright (c) the ocp_gordon authors',
        source_url='https://github.com/bernhard-42/ocp-gordon',
        license_files=('ocp-gordon-0.2.2.LICENSE.txt',),
        note='Gordon-surface construction on top of OCP; a build123d '
             'dependency.',
    ),
    RuntimeComponent(
        distribution='ocpsvg',
        component='ocpsvg',
        version='0.5.0',
        license='Apache-2.0',
        copyright='Copyright (c) the ocpsvg authors',
        source_url='https://github.com/snoyer/ocpsvg',
        license_files=('ocpsvg-0.5.0.LICENSE.txt',),
        note='SVG-to-OCCT-geometry conversion; a build123d dependency.',
    ),
    RuntimeComponent(
        distribution='packaging',
        component='packaging',
        version='26.3',
        license='Apache-2.0 OR BSD-2-Clause',
        copyright='Copyright (c) Donald Stufft and individual contributors.',
        source_url='https://github.com/pypa/packaging',
        license_files=('packaging-26.3.LICENSE.APACHE.txt',
                        'packaging-26.3.LICENSE.BSD.txt',
                        'packaging-26.3.LICENSE.txt'),
        note='Version parsing, used by several of the wheels above. '
             "Dual-licensed at the recipient's choice, so both texts and the "
             'choice note ship.',
    ),
    RuntimeComponent(
        distribution='parso',
        component='parso',
        version='0.8.7',
        license='MIT',
        copyright='Copyright (c) <2013-2017> <David Halter and others, see '
                  'AUTHORS.txt>',
        source_url='https://github.com/davidhalter/parso',
        license_files=('parso-0.8.7.LICENSE.txt',),
        note='jedi dependency.',
    ),
    RuntimeComponent(
        distribution='pexpect',
        component='pexpect',
        version='4.9.0',
        license='ISC',
        copyright='Copyright (c) 2013-2014, Pexpect development team; Copyright '
                  '(c) 2012, Noah Spurrier',
        source_url='https://github.com/pexpect/pexpect',
        license_files=('pexpect-4.9.0.LICENSE.txt',),
        note='IPython dependency on POSIX.',
    ),
    RuntimeComponent(
        distribution='pillow',
        component='pillow',
        version='12.3.0',
        license='HPND',
        copyright='Copyright (c) 1997-2011 by Secret Labs AB; Copyright (c) '
                  '1995-2011 by Fredrik Lundh; Copyright (c) 2010 by Jeffrey A. '
                  'Clark and contributors',
        source_url='https://github.com/python-pillow/Pillow',
        license_files=('pillow-12.3.0.LICENSE.txt',),
        note='Image I/O for matplotlib. Its licence is the historical PIL '
             'permission notice (HPND, declared MIT-CMU in the wheel '
             'metadata).',
    ),
    RuntimeComponent(
        distribution='pip',
        component='pip',
        version='26.1.1',
        license='MIT',
        copyright='Copyright (c) 2008-present The pip developers (see AUTHORS.txt '
                  'file)',
        source_url='https://github.com/pypa/pip',
        license_files=('pip-26.1.1.LICENSE.txt',),
        note="Ships because python-build-standalone's interpreter includes "
             'it; the worker never runs it. The wheel also vendors ~20 '
             'libraries of its own under pip/_vendor with their texts in its '
             'dist-info — those are not separately inventoried here because '
             "pip is not on the worker's import path.",
    ),
    RuntimeComponent(
        distribution='prompt-toolkit',
        component='prompt-toolkit',
        version='3.0.53',
        license='BSD-3-Clause',
        copyright='Copyright (c) 2014, Jonathan Slenders',
        source_url='https://github.com/prompt-toolkit/python-prompt-toolkit',
        license_files=('prompt-toolkit-3.0.53.LICENSE.txt',),
        note='IPython dependency.',
    ),
    RuntimeComponent(
        distribution='psutil',
        component='psutil',
        version='7.2.2',
        license='BSD-3-Clause',
        copyright='Copyright (c) 2009, Jay Loden, Dave Daeschler, Giampaolo '
                  'Rodola',
        source_url='https://github.com/giampaolo/psutil',
        license_files=('psutil-7.2.2.LICENSE.txt',),
        note='Process introspection; transitive.',
    ),
    RuntimeComponent(
        distribution='ptyprocess',
        component='ptyprocess',
        version='0.7.0',
        license='ISC',
        copyright='Copyright (c) 2013-2014, Pexpect development team; Copyright '
                  '(c) 2012, Noah Spurrier',
        source_url='https://github.com/pexpect/ptyprocess',
        license_files=('ptyprocess-0.7.0.LICENSE.txt',),
        note='pexpect dependency. Its METADATA says License: UNKNOWN; the '
             'shipped text is the ISC licence, which is what this entry '
             'records.',
    ),
    RuntimeComponent(
        distribution='pure-eval',
        component='pure-eval',
        version='0.2.3',
        license='MIT',
        copyright='Copyright (c) 2019 Alex Hall',
        source_url='https://github.com/alexmojaki/pure_eval',
        license_files=('pure-eval-0.2.3.LICENSE.txt',),
        note='stack-data dependency.',
    ),
    RuntimeComponent(
        distribution='pygments',
        component='pygments',
        version='2.21.0',
        license='BSD-2-Clause',
        copyright='Copyright (c) 2006-2022 by the respective authors (see AUTHORS '
                  'file).',
        source_url='https://github.com/pygments/pygments',
        license_files=('pygments-2.21.0.LICENSE.txt',),
        note='IPython syntax highlighting.',
    ),
    RuntimeComponent(
        distribution='pyparsing',
        component='pyparsing',
        version='3.3.2',
        license='MIT',
        copyright='Copyright (c) 2003-2025  Paul McGuire',
        source_url='https://github.com/pyparsing/pyparsing',
        license_files=('pyparsing-3.3.2.LICENSE.txt',),
        note='matplotlib dependency.',
    ),
    RuntimeComponent(
        distribution='python-dateutil',
        component='python-dateutil',
        version='2.9.0.post0',
        license='Apache-2.0 AND BSD-3-Clause',
        copyright='Copyright 2017- Paul Ganssle; Copyright 2017- dateutil '
                  'contributors (see AUTHORS file)',
        source_url='https://github.com/dateutil/dateutil',
        license_files=('python-dateutil-2.9.0.post0.LICENSE.txt',),
        note='matplotlib dependency. Dual-licensed: the shipped text carries '
             'both the Apache-2.0 grant and the original BSD-3-Clause terms, '
             'which is why the id is an AND rather than a choice.',
    ),
    RuntimeComponent(
        distribution='scipy',
        component='scipy',
        version='1.18.1',
        license='BSD-3-Clause',
        copyright='Copyright (c) 2001-2002 Enthought, Inc. 2003, SciPy '
                  'Developers.',
        source_url='https://github.com/scipy/scipy',
        license_files=('scipy-1.18.1.LICENSE.txt',),
        note="Numerics used by the worker's geometry checks.",
    ),
    RuntimeComponent(
        distribution='six',
        component='six',
        version='1.17.0',
        license='MIT',
        copyright='Copyright (c) 2010-2024 Benjamin Peterson',
        source_url='https://github.com/benjaminp/six',
        license_files=('six-1.17.0.LICENSE.txt',),
        note='python-dateutil dependency.',
    ),
    RuntimeComponent(
        distribution='stack-data',
        component='stack-data',
        version='0.6.3',
        license='MIT',
        copyright='Copyright (c) 2019 Alex Hall',
        source_url='https://github.com/alexmojaki/stack_data',
        license_files=('stack-data-0.6.3.LICENSE.txt',),
        note='IPython traceback dependency.',
    ),
    RuntimeComponent(
        distribution='svgelements',
        component='svgelements',
        version='1.9.6',
        license='MIT',
        copyright='Copyright (c) 2019 meerk40t',
        source_url='https://github.com/meerk40t/svgelements',
        license_files=('svgelements-1.9.6.LICENSE.txt',),
        note='SVG parsing; an ocpsvg/build123d dependency.',
    ),
    RuntimeComponent(
        distribution='svgpathtools',
        component='svgpathtools',
        version='1.7.4',
        license='MIT',
        copyright='Copyright (c) 2015 Andrew Allan Port',
        source_url='https://github.com/mathandy/svgpathtools',
        license_files=('svgpathtools-1.7.4.LICENSE.txt',),
        note='SVG path maths; a build123d dependency.',
    ),
    RuntimeComponent(
        distribution='svgwrite',
        component='svgwrite',
        version='1.4.3',
        license='MIT',
        copyright='Copyright (c) 2012, Manfred Moitzi',
        source_url='https://github.com/mozman/svgwrite',
        license_files=('svgwrite-1.4.3.LICENSE.txt',),
        note="SVG output for build123d's 2D exports.",
    ),
    RuntimeComponent(
        distribution='sympy',
        component='sympy',
        version='1.14.0',
        license='BSD-3-Clause',
        copyright='Copyright (c) 2006-2023 SymPy Development Team',
        source_url='https://github.com/sympy/sympy',
        license_files=('sympy-1.14.0.LICENSE.txt',),
        note='Symbolic maths; a build123d dependency.',
    ),
    RuntimeComponent(
        distribution='traitlets',
        component='traitlets',
        version='5.16.1',
        license='BSD-3-Clause',
        copyright='Copyright (c) 2001-, IPython Development Team',
        source_url='https://github.com/ipython/traitlets',
        license_files=('traitlets-5.16.1.LICENSE.txt',),
        note='IPython configuration system.',
    ),
    RuntimeComponent(
        distribution='trianglesolver',
        component='trianglesolver',
        version='1.2',
        license='MIT',
        copyright='Copyright (c) 2014 Steven Byrnes',
        source_url='https://github.com/sbyrnes321/trianglesolver',
        license_files=('trianglesolver-1.2.LICENSE.txt',),
        note='Triangle solving; a build123d dependency. The wheel ships '
             'its LICENSE.txt as cp1252; the copy here is the same text '
             'transcoded to UTF-8 so it is readable everywhere it ships.',
    ),
    RuntimeComponent(
        distribution='typing-extensions',
        component='typing-extensions',
        version='4.16.0',
        license='PSF-2.0',
        copyright='Copyright (c) 2001-2024 Python Software Foundation',
        source_url='https://github.com/python/typing_extensions',
        license_files=('typing-extensions-4.16.0.LICENSE.txt',),
        note='Typing backports. Licensed under the Python Software '
             'Foundation License, whose full text (the CPython LICENSE, '
             'including the historical CWI and BeOpen notices) ships here.',
    ),
    RuntimeComponent(
        distribution='vtk',
        component='vtk',
        version='9.3.1',
        license='BSD-3-Clause',
        copyright='Copyright (c) 1993-2015 Ken Martin, Will Schroeder, Bill '
                  'Lorensen',
        source_url='https://gitlab.kitware.com/vtk/vtk',
        license_files=('vtk-9.3.1.LICENSE.txt',),
        note="Visualisation toolkit; pulled in by cadquery-ocp's VTK-enabled "
             'build. Its wheel carries the compiled VTK shared libraries.',
    ),
    RuntimeComponent(
        distribution='wcwidth',
        component='wcwidth',
        version='0.8.3',
        license='MIT',
        copyright='Copyright (c) 2014 Jeff Quast <contact@jeffquast.com>',
        source_url='https://github.com/jquast/wcwidth',
        license_files=('wcwidth-0.8.3.LICENSE.txt',),
        note='prompt-toolkit dependency.',
    ),
    RuntimeComponent(
        distribution='webcolors',
        component='webcolors',
        version='24.8.0',
        license='BSD-3-Clause',
        copyright='Copyright (c) James Bennett, and contributors.',
        source_url='https://github.com/ubernostrum/webcolors',
        license_files=('webcolors-24.8.0.LICENSE.txt',),
        note='Colour-name parsing; a build123d dependency.',
    ),
)

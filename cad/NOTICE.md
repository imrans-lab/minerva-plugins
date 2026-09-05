# NOTICE — cad runtime bundle

**This file is GENERATED. Do not hand-edit it.**

Regenerate with:

    python3 cad/scripts/gen_notice.py

Licence and attribution inventory for the third-party content that ships inside the cad plugin's embedded Python runtime bundle. The full text of every licence below is in `cad/licenses/runtime/`, which is copied into the bundle (as `licenses/`) and into the release tarball beside the plugin binary — BSD and MIT terms require the notice, conditions and disclaimer to be provided with a binary distribution, so naming the licence here is not on its own enough.

The inventory is checked against a census of the built bundle's site-packages (`cad/scripts/runtime-bundle.manifest`), not against the two pins in `cad/scripts/runtime-bundle.lock`: pip resolves the transitive tree, so the lock names 2 distributions and the bundle contains 47. Wheel metadata cannot see what a wheel vendors either — python-fcl's contains compiled FCL, libccd, OctoMap and Eigen while shipping only python-fcl's LICENSE, and cadquery-ocp's contains the whole of OCCT while shipping no licence text at all — so the inventory is maintained by hand in `cad/scripts/notice_inventory.py` and `gen_notice.py --check` is the gate that keeps it honest.

Lock pins: build123d, python-fcl

Census: 47 distributions in the built bundle's site-packages, 53 inventoried components (a distribution yields more than one entry when its wheel vendors other projects), 0 excluded.

## python-fcl 0.7.0.11

- Licence: BSD-3-Clause
- Copyright (c) 2017, Matthew Matl
- Source: https://github.com/BerkeleyAutomation/python-fcl
- Arrives via: `python-fcl` wheel
- Licence text: `cad/licenses/runtime/python-fcl-0.7.0.11.LICENSE.txt` (sha256 227477911a47ec8250034733807518856b1bc94dc00bb714fc0ab7b26e2d6a14)

Cython bindings to FCL. The only licence the wheel itself ships; the four components below are compiled into it.

## FCL (Flexible Collision Library) 0.7.0

- Licence: BSD-3-Clause
- Copyright (c) 2008-2014, Willow Garage, Inc.; Copyright (c) 2014-2016, Open Source Robotics Foundation
- Source: https://github.com/flexible-collision-library/fcl/tree/0.7.0
- Arrives via: `python-fcl` wheel
- Licence text: `cad/licenses/runtime/fcl-0.7.0.LICENSE.txt` (sha256 899258d09bf54d5d11eee2567e6cf72f7927a81267959db4baa3468a70fd8703)

Built by python-fcl from the ambi-robotics/fcl fork pinned at FCL 0.7.0. Ships as libfcl (linux/macOS) or linked into fcl.cp312-win_amd64.pyd (Windows).

## libccd 2.1

- Licence: BSD-3-Clause
- Copyright (c) 2010-2012 Daniel Fiser <danfis@danfis.cz>, Intelligent and Mobile Robotics Group, Czech Technical University in Prague
- Source: https://github.com/danfis/libccd/tree/v2.1
- Arrives via: `python-fcl` wheel
- Licence text: `cad/licenses/runtime/libccd-2.1.BSD-LICENSE.txt` (sha256 b175a981bfccf7e1e6c2f6fbda3fde0827aaa51808a983b10c8c7e6183c44a11)

FCL's convex-collision backend. Ships as libccd / ccd.dll.

## OctoMap (octomap + octomath) 1.9.8

- Licence: BSD-3-Clause
- Copyright (c) 2009-2013, K.M. Wurm and A. Hornung, University of Freiburg
- Source: https://github.com/OctoMap/octomap/tree/v1.9.8
- Arrives via: `python-fcl` wheel
- Licence text: `cad/licenses/runtime/octomap-1.9.8.LICENSE.txt` (sha256 8a9ce1eadc1dd0fc4ee57a6016cb40eddc7003d2da824c58d55463f2b9ceb4ca)

FCL's octree collision geometry. Only the New-BSD octomap and octomath libraries are in the wheel — octovis, the GPL viewer in the same upstream repository, is not.

## Eigen 3.3.9

- Licence: MPL-2.0
- Copyright (c) the Eigen authors (see the upstream source for per-file notices)
- Source: https://gitlab.com/libeigen/eigen/-/archive/3.3.9/eigen-3.3.9.tar.gz
- Arrives via: `python-fcl` wheel
- Licence text: `cad/licenses/runtime/eigen-3.3.9.COPYING.MPL2.txt` (sha256 fab3dd6bdab226f1c08630b1dd917e11fcb4ec5e1e020e2c16f83a0a13863e85)
- Licence text: `cad/licenses/runtime/eigen-3.3.9.COPYING.README.txt` (sha256 c83230b770f17ef1386ea1fd3681271dd98aa93646bdbfb5bff3a1b7050fff9d)

Header-only, compiled unmodified into libfcl, so no Eigen file appears in the bundle. FCL 0.7.0 includes only <Eigen/Core>, <Eigen/Dense> and <Eigen/StdVector>; Eigen's two LGPL-2.1 files (IterativeLinearSolvers/IncompleteLUT.h, SparseCholesky/SimplicialCholesky_impl.h) are sparse-solver headers FCL never includes, so no LGPL code is compiled in. Re-check this on any Eigen or FCL version bump.

**Source availability and relinking.** Eigen 3.3.9's MPL-2.0 source is at https://gitlab.com/libeigen/eigen/-/archive/3.3.9/eigen-3.3.9.tar.gz. The covered files are unmodified upstream headers compiled into libfcl, so a recipient who wants a modified Eigen rebuilds python-fcl from its own source against that archive; nothing in this bundle carries Eigen source of its own.

## Microsoft Visual C++ runtime (MSVCP140.dll and the VCRUNTIME140 pair) Visual Studio 2022 redistributable

- Licence: LicenseRef-Microsoft-VC-Redistributable
- Copyright (c) Microsoft Corporation
- Source: https://learn.microsoft.com/en-us/visualstudio/releases/2022/redistribution
- Arrives via: not a PyPI distribution
- Licence text: `cad/licenses/runtime/microsoft-vc-runtime.ATTRIBUTION.txt` (sha256 a09ab0e549aaa77c391da589fbbb865921686c3eb68a73e10c48386d60a2d953)

Windows bundle only. The python-fcl extension imports MSVCP140.dll, which python-build-standalone does not ship, so the Windows build repairs the wheel with delvewheel and the DLL travels inside the bundle instead of being resolved from the user's machine. Nothing is checked into this repository.

## anytree 2.13.0

- Licence: Apache-2.0
- Copyright (c) 2016 c0fec0de
- Source: https://github.com/c0fec0de/anytree
- Arrives via: `anytree` wheel
- Licence text: `cad/licenses/runtime/anytree-2.13.0.LICENSE.txt` (sha256 b40930bbcf80744c86c46a12bc9da056641d722716c378f5659b9e555ef833e1)

Tree data structure used by build123d to model assembly hierarchies.

## asttokens 3.0.2

- Licence: Apache-2.0
- Copyright (c) 2016, Grist Labs, Inc.
- Source: https://github.com/gristlabs/asttokens
- Arrives via: `asttokens` wheel
- Licence text: `cad/licenses/runtime/asttokens-3.0.2.LICENSE.txt` (sha256 62fb8a3a9621dc2388174caaabe9c2317b694bb9a1d46c98bcf5655b68f51be3)

Pulled in by stack-data, which IPython uses for tracebacks.

## build123d 0.10.0

- Licence: Apache-2.0
- Copyright 2022 Roger Maitland
- Source: https://github.com/gumyr/build123d
- Arrives via: `build123d` wheel
- Licence text: `cad/licenses/runtime/build123d-0.10.0.LICENSE.txt` (sha256 cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30)
- Licence text: `cad/licenses/runtime/build123d-0.10.0.NOTICE.txt` (sha256 7b7c0e58f119b8e17eba8faa015ab48dedd1131836d30c8a56fa6dbf56d22ce0)

The modelling API the cad worker is written against — the reason the bundle exists. Its wheel ships an Apache-2.0 NOTICE, which section 4(d) requires to travel with any distribution, so both texts are inventoried.

## cadquery-ocp 7.8.1.1.post1

- Licence: Apache-2.0
- Copyright (c) the OCP authors
- Source: https://github.com/CadQuery/OCP
- Arrives via: `cadquery-ocp` wheel
- Licence text: `cad/licenses/runtime/cadquery-ocp-7.8.1.1.post1.OCP-LICENSE.txt` (sha256 a13caea71627202ad33cc4cafafdd18e667e16716488f8d9c568127121fb89fd)

pybind11 bindings to Open CASCADE Technology. The wheel ships NO licence text of its own, so the Apache-2.0 text here is taken from the OCP repository. The wheel also vendors OCCT itself as shared libraries — see the OCCT entry below, and note the wheel additionally vendors ~22 unrelated native libraries whose licences are NOT covered by this inventory.

## Open CASCADE Technology (OCCT) 7.8.1

- Licence: LGPL-2.1-only WITH OCCT-exception-1.0
- Copyright (c) 1999-2024 OPEN CASCADE SAS
- Source: https://github.com/Open-Cascade-SAS/OCCT/tree/V7_8_1
- Arrives via: `cadquery-ocp` wheel
- Licence text: `cad/licenses/runtime/occt-7.8.1.LICENSE_LGPL_21.txt` (sha256 e237fa56668030e928551ddd60f05df5fe957f75eab874bbd017e085ed722e7c)
- Licence text: `cad/licenses/runtime/occt-7.8.1.OCCT_LGPL_EXCEPTION.txt` (sha256 04580a884ea6cea294402649ff7b5cbb167d47462d1340a4ed33e550db10a81b)

The geometry kernel every modelling operation in the cad worker ends up in. It reaches the bundle inside the cadquery-ocp wheel rather than as a distribution of its own, so no dist-info names it and a census of site-packages cannot find it — the same blind spot as python-fcl's vendored tree. Version read off the vendored sonames (libTK*.so.7.8.1) and confirmed by cadquery-ocp's own 7.8.1.x version line.

**Source availability and relinking.** OCCT is DYNAMICALLY LINKED, not compiled in: the cadquery-ocp wheel ships OCCT as separate shared libraries (site-packages/cadquery_ocp.libs/libTK*.so.7.8.1 on linux, the matching .dylib set on macOS, TK*.dll beside the OCP extension on windows), and the OCP extension resolves them through the dynamic loader at import time. Under LGPL-2.1 section 6 that means a recipient must be able to modify OCCT and relink. Complete corresponding source for OCCT 7.8.1 is at https://github.com/Open-Cascade-SAS/OCCT/tree/V7_8_1 (also released by Open CASCADE SAS at https://dev.opencascade.org/release). To relink: extract the runtime bundle, build OCCT 7.8.1 (or a modified OCCT) with the same soname, and replace the corresponding files in cadquery_ocp.libs/ — the cad plugin binary itself needs no rebuild, because nothing in it links OCCT statically. The Open CASCADE exception additionally permits the object code of a work that uses the library to incorporate material from OCCT header files.

## cadquery-ocp-proxy 7.9.3.1.1

- Licence: Apache-2.0
- Copyright (c) Bernhard Walter
- Source: https://pypi.org/project/cadquery-ocp-proxy/
- Arrives via: `cadquery-ocp-proxy` wheel
- Licence text: `cad/licenses/runtime/cadquery-ocp-proxy-7.9.3.1.1.LICENSE.txt` (sha256 cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30)

A no-op package (an __init__.py and a _version.py) whose only job is to pin which cadquery-ocp variant resolves. Its wheel ships no licence text and its repository is not public, so the canonical Apache-2.0 text is used, matching the Apache-2.0 its METADATA declares.

## contourpy 1.3.3

- Licence: BSD-3-Clause
- Copyright (c) 2021-2025, ContourPy Developers.
- Source: https://github.com/contourpy/contourpy
- Arrives via: `contourpy` wheel
- Licence text: `cad/licenses/runtime/contourpy-1.3.3.LICENSE.txt` (sha256 34170979fc64f4f5e6dfa66ef27dec314ffffc5852000c60f4836ec1dfbf156e)

matplotlib's contour engine.

## cycler 0.12.1

- Licence: BSD-3-Clause
- Copyright (c) 2015, matplotlib project
- Source: https://github.com/matplotlib/cycler
- Arrives via: `cycler` wheel
- Licence text: `cad/licenses/runtime/cycler-0.12.1.LICENSE.txt` (sha256 f1218143d766da3fea66f13396b7f15df46a83303f29bf96ba6e98eb4d42f408)

matplotlib dependency.

## executing 2.2.1

- Licence: MIT
- Copyright (c) 2019 Alex Hall
- Source: https://github.com/alexmojaki/executing
- Arrives via: `executing` wheel
- Licence text: `cad/licenses/runtime/executing-2.2.1.LICENSE.txt` (sha256 a476a2cb0ef4c41450340a577a28b91ac4c7f669136b2ee148047fabd5fc4181)

stack-data dependency.

## ezdxf 1.4.4

- Licence: MIT
- Copyright (c) 2020 Manfred Moitzi
- Source: https://github.com/mozman/ezdxf
- Arrives via: `ezdxf` wheel
- Licence text: `cad/licenses/runtime/ezdxf-1.4.4.LICENSE.txt` (sha256 db97ca426fc0d2b8124145de0f36181db73e6e713ce642d42fed2efc442edf19)

DXF reader/writer build123d uses for 2D import and export.

## fonttools 4.63.0

- Licence: MIT
- Copyright (c) 2017 Just van Rossum
- Source: https://github.com/fonttools/fonttools
- Arrives via: `fonttools` wheel
- Licence text: `cad/licenses/runtime/fonttools-4.63.0.LICENSE.external.txt` (sha256 94a83aaee0729a0f302d34acc4acecbd9d58366f262429075fe557e4a54b2e69)
- Licence text: `cad/licenses/runtime/fonttools-4.63.0.LICENSE.txt` (sha256 6787208f83f659ccbc2223b2fde952ffa6f7e8aca62f1a8a2bf5bc51bb1b2383)

Font parsing for matplotlib and for build123d's text features. Its LICENSE.external records the terms of the fonts and third-party code the project carries, and is inventoried alongside the MIT text.

## ipython 9.16.1

- Licence: BSD-3-Clause
- Copyright (c) 2008-Present, IPython Development Team; Copyright (c) 2001-2007, Fernando Perez
- Source: https://github.com/ipython/ipython
- Arrives via: `ipython` wheel
- Licence text: `cad/licenses/runtime/ipython-9.16.1.LICENSE.txt` (sha256 e0e390748ed440ab893ca1f135a88a920aaf5409dbb90a5b427c75c5e51268fb)

Transitive through build123d. Nothing in the cad worker imports it; it ships because pip resolved it.

## ipython-pygments-lexers 1.1.1

- Licence: BSD-3-Clause
- Copyright (c) 2012-Present, IPython Development Team
- Source: https://github.com/ipython/ipython-pygments-lexers
- Arrives via: `ipython-pygments-lexers` wheel
- Licence text: `cad/licenses/runtime/ipython-pygments-lexers-1.1.1.LICENSE.txt` (sha256 b1d0dbc0fa79774d34b8e2d0aec91d50d8caf05f7b40fc22c3010a4bd9ad2bf9)

IPython dependency.

## jedi 0.20.0

- Licence: MIT
- Copyright (c) <2013> <David Halter and others, see AUTHORS.txt>
- Source: https://github.com/davidhalter/jedi
- Arrives via: `jedi` wheel
- Licence text: `cad/licenses/runtime/jedi-0.20.0.LICENSE.txt` (sha256 78e60cd0b8f28694f30195482c33d76908d846b0d15278deb7332aa22ba8e412)

IPython completion dependency.

## kiwisolver 1.5.0

- Licence: BSD-3-Clause
- Copyright (c) 2013-2026, Nucleic Development Team
- Source: https://github.com/nucleic/kiwi
- Arrives via: `kiwisolver` wheel
- Licence text: `cad/licenses/runtime/kiwisolver-1.5.0.LICENSE.txt` (sha256 529c40e5f67f2f88904657a9f7879ae2f8dc76bc9bfef9cb10d988b48804ed61)

matplotlib's layout solver.

## lib3mf 2.5.0

- Licence: BSD-2-Clause
- Copyright (c) 2024, 3MF Consortium
- Source: https://github.com/3MFConsortium/lib3mf
- Arrives via: `lib3mf` wheel
- Licence text: `cad/licenses/runtime/lib3mf-2.5.0.LICENSE.txt` (sha256 34d8c9d9147e6550fa46f7f1184bf03bbf3e3495051b87695191525663b0fc58)

3MF read/write. The wheel carries the compiled lib3mf shared library.

## matplotlib 3.11.1

- Licence: LicenseRef-Matplotlib-PSF
- Copyright (c) 2012- Matplotlib Development Team; Copyright (c) 2002-2011 John D. Hunter
- Source: https://github.com/matplotlib/matplotlib
- Arrives via: `matplotlib` wheel
- Licence text: `cad/licenses/runtime/matplotlib-3.11.1.LICENSE.txt` (sha256 822e8e528147569a41975592aee19c11992ab667ba50451cd929031d5fc74491)

Transitive through build123d's plotting helpers. Its licence is a PSF-derived agreement of its own rather than an SPDX-listed one, so it is carried under a LicenseRef id and its full text is shipped; the terms are permissive (attribution plus the summary of changes).

## matplotlib-inline 0.2.2

- Licence: BSD-3-Clause
- Copyright (c) 2019-2022, IPython Development Team.
- Source: https://github.com/ipython/matplotlib-inline
- Arrives via: `matplotlib-inline` wheel
- Licence text: `cad/licenses/runtime/matplotlib-inline-0.2.2.LICENSE.txt` (sha256 8521b036c6448e0e0aa7213d4713b6fdee0f4c64c9f320450f77346bf5c0e8e4)

IPython/matplotlib glue.

## mpmath 1.3.0

- Licence: BSD-3-Clause
- Copyright (c) 2005-2021 Fredrik Johansson and mpmath contributors
- Source: https://github.com/mpmath/mpmath
- Arrives via: `mpmath` wheel
- Licence text: `cad/licenses/runtime/mpmath-1.3.0.LICENSE.txt` (sha256 c26cae81da4508e5e249985777a33821f183223ebb74d7f8cfbf90fe7eef2fb7)

sympy dependency.

## numpy 2.5.2

- Licence: BSD-3-Clause
- Copyright (c) 2005-2025, NumPy Developers.
- Source: https://github.com/numpy/numpy
- Arrives via: `numpy` wheel
- Licence text: `cad/licenses/runtime/numpy-2.5.2.LICENSE.txt` (sha256 4860083caa0de2ac3292ca98bd074bd8f45d8b32624e37b1e70a240bff61e488)

Array backbone for the worker's geometry code. The wheel additionally ships per-component texts under its dist-info for the code it vendors (Mersenne Twister, PCG64, pocketfft, LAPACK-lite, highway, dragon4, libdivide, x86-simd-sort); the top-level BSD-3-Clause text inventoried here is the one that covers NumPy itself.

## ocp-gordon 0.2.2

- Licence: Apache-2.0
- Copyright (c) the ocp_gordon authors
- Source: https://github.com/bernhard-42/ocp-gordon
- Arrives via: `ocp-gordon` wheel
- Licence text: `cad/licenses/runtime/ocp-gordon-0.2.2.LICENSE.txt` (sha256 7bb09ea8b8d885a5012a8da97c3e8929130e0019f8c62e17bc4def88e9bd2594)

Gordon-surface construction on top of OCP; a build123d dependency.

## ocpsvg 0.5.0

- Licence: Apache-2.0
- Copyright (c) the ocpsvg authors
- Source: https://github.com/snoyer/ocpsvg
- Arrives via: `ocpsvg` wheel
- Licence text: `cad/licenses/runtime/ocpsvg-0.5.0.LICENSE.txt` (sha256 c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4)

SVG-to-OCCT-geometry conversion; a build123d dependency.

## packaging 26.3

- Licence: Apache-2.0 OR BSD-2-Clause
- Copyright (c) Donald Stufft and individual contributors.
- Source: https://github.com/pypa/packaging
- Arrives via: `packaging` wheel
- Licence text: `cad/licenses/runtime/packaging-26.3.LICENSE.APACHE.txt` (sha256 0d542e0c8804e39aa7f37eb00da5a762149dc682d7829451287e11b938e94594)
- Licence text: `cad/licenses/runtime/packaging-26.3.LICENSE.BSD.txt` (sha256 b70e7e9b742f1cc6f948b34c16aa39ffece94196364bc88ff0d2180f0028fac5)
- Licence text: `cad/licenses/runtime/packaging-26.3.LICENSE.txt` (sha256 cad1ef5bd340d73e074ba614d26f7deaca5c7940c3d8c34852e65c4909686c48)

Version parsing, used by several of the wheels above. Dual-licensed at the recipient's choice, so both texts and the choice note ship.

## parso 0.8.7

- Licence: MIT
- Copyright (c) <2013-2017> <David Halter and others, see AUTHORS.txt>
- Source: https://github.com/davidhalter/parso
- Arrives via: `parso` wheel
- Licence text: `cad/licenses/runtime/parso-0.8.7.LICENSE.txt` (sha256 fa67973073753d17624caf8684d5ee816d70c89d912c5bca7ca0f08e7b150edb)

jedi dependency.

## pexpect 4.9.0

- Licence: ISC
- Copyright (c) 2013-2014, Pexpect development team; Copyright (c) 2012, Noah Spurrier
- Source: https://github.com/pexpect/pexpect
- Arrives via: `pexpect` wheel
- Licence text: `cad/licenses/runtime/pexpect-4.9.0.LICENSE.txt` (sha256 4a483ae1c4dc738a6c8b73feb49074e1835da02ab5aa686f2675029906fa364d)

IPython dependency on POSIX.

## pillow 12.3.0

- Licence: HPND
- Copyright (c) 1997-2011 by Secret Labs AB; Copyright (c) 1995-2011 by Fredrik Lundh; Copyright (c) 2010 by Jeffrey A. Clark and contributors
- Source: https://github.com/python-pillow/Pillow
- Arrives via: `pillow` wheel
- Licence text: `cad/licenses/runtime/pillow-12.3.0.LICENSE.txt` (sha256 dda12a98c1979cf3d94df1cff45d27a4cb3f04a60c76f76902ac54cac03ec0ce)

Image I/O for matplotlib. Its licence is the historical PIL permission notice (HPND, declared MIT-CMU in the wheel metadata).

## pip 26.1.1

- Licence: MIT
- Copyright (c) 2008-present The pip developers (see AUTHORS.txt file)
- Source: https://github.com/pypa/pip
- Arrives via: `pip` wheel
- Licence text: `cad/licenses/runtime/pip-26.1.1.LICENSE.txt` (sha256 634300a669d49aeae65b12c6c48c924c51a4cdf3d1ff086dc3456dc8bcaa2104)

Ships because python-build-standalone's interpreter includes it; the worker never runs it. The wheel also vendors ~20 libraries of its own under pip/_vendor with their texts in its dist-info — those are not separately inventoried here because pip is not on the worker's import path.

## prompt-toolkit 3.0.53

- Licence: BSD-3-Clause
- Copyright (c) 2014, Jonathan Slenders
- Source: https://github.com/prompt-toolkit/python-prompt-toolkit
- Arrives via: `prompt-toolkit` wheel
- Licence text: `cad/licenses/runtime/prompt-toolkit-3.0.53.LICENSE.txt` (sha256 303574d9bdd85c757d6025017942bf17baeedf2778f62bd7f425d07d880f4c4a)

IPython dependency.

## psutil 7.2.2

- Licence: BSD-3-Clause
- Copyright (c) 2009, Jay Loden, Dave Daeschler, Giampaolo Rodola
- Source: https://github.com/giampaolo/psutil
- Arrives via: `psutil` wheel
- Licence text: `cad/licenses/runtime/psutil-7.2.2.LICENSE.txt` (sha256 b89c063b3786e28e0c0a38f1931db61fed35e69dd2a2966fbecffee0f46c8d10)

Process introspection; transitive.

## ptyprocess 0.7.0

- Licence: ISC
- Copyright (c) 2013-2014, Pexpect development team; Copyright (c) 2012, Noah Spurrier
- Source: https://github.com/pexpect/ptyprocess
- Arrives via: `ptyprocess` wheel
- Licence text: `cad/licenses/runtime/ptyprocess-0.7.0.LICENSE.txt` (sha256 c822d385b1a73329846241799becf18690b5d44764c1bed69300b536a405030a)

pexpect dependency. Its METADATA says License: UNKNOWN; the shipped text is the ISC licence, which is what this entry records.

## pure-eval 0.2.3

- Licence: MIT
- Copyright (c) 2019 Alex Hall
- Source: https://github.com/alexmojaki/pure_eval
- Arrives via: `pure-eval` wheel
- Licence text: `cad/licenses/runtime/pure-eval-0.2.3.LICENSE.txt` (sha256 a476a2cb0ef4c41450340a577a28b91ac4c7f669136b2ee148047fabd5fc4181)

stack-data dependency.

## pygments 2.20.0

- Licence: BSD-2-Clause
- Copyright (c) 2006-2022 by the respective authors (see AUTHORS file).
- Source: https://github.com/pygments/pygments
- Arrives via: `pygments` wheel
- Licence text: `cad/licenses/runtime/pygments-2.20.0.LICENSE.txt` (sha256 a9d66f1d526df02e29dce73436d34e56e8632f46c275bbdffc70569e882f9f17)

IPython syntax highlighting.

## pyparsing 3.3.2

- Licence: MIT
- Copyright (c) 2003-2025  Paul McGuire
- Source: https://github.com/pyparsing/pyparsing
- Arrives via: `pyparsing` wheel
- Licence text: `cad/licenses/runtime/pyparsing-3.3.2.LICENSE.txt` (sha256 a5425f9dc14ac74d4c5f0b679e941f2442e32cca7452a4418d5b1a49893ebe4e)

matplotlib dependency.

## python-dateutil 2.9.0.post0

- Licence: Apache-2.0 AND BSD-3-Clause
- Copyright 2017- Paul Ganssle; Copyright 2017- dateutil contributors (see AUTHORS file)
- Source: https://github.com/dateutil/dateutil
- Arrives via: `python-dateutil` wheel
- Licence text: `cad/licenses/runtime/python-dateutil-2.9.0.post0.LICENSE.txt` (sha256 ba00f51a0d92823b5a1cde27d8b5b9d2321e67ed8da9bc163eff96d5e17e577e)

matplotlib dependency. Dual-licensed: the shipped text carries both the Apache-2.0 grant and the original BSD-3-Clause terms, which is why the id is an AND rather than a choice.

## scipy 1.18.0

- Licence: BSD-3-Clause
- Copyright (c) 2001-2002 Enthought, Inc. 2003, SciPy Developers.
- Source: https://github.com/scipy/scipy
- Arrives via: `scipy` wheel
- Licence text: `cad/licenses/runtime/scipy-1.18.0.LICENSE.txt` (sha256 17e7db9ffa4913121fa2df484633a362456a482da736c99db4711a98473770ea)

Numerics used by the worker's geometry checks.

## six 1.17.0

- Licence: MIT
- Copyright (c) 2010-2024 Benjamin Peterson
- Source: https://github.com/benjaminp/six
- Arrives via: `six` wheel
- Licence text: `cad/licenses/runtime/six-1.17.0.LICENSE.txt` (sha256 4375ba20e2b9c6c4e7cad2940a628fd90e95cc3d50ee92aae755715d8ba1fbd0)

python-dateutil dependency.

## stack-data 0.6.3

- Licence: MIT
- Copyright (c) 2019 Alex Hall
- Source: https://github.com/alexmojaki/stack_data
- Arrives via: `stack-data` wheel
- Licence text: `cad/licenses/runtime/stack-data-0.6.3.LICENSE.txt` (sha256 a476a2cb0ef4c41450340a577a28b91ac4c7f669136b2ee148047fabd5fc4181)

IPython traceback dependency.

## svgelements 1.9.6

- Licence: MIT
- Copyright (c) 2019 meerk40t
- Source: https://github.com/meerk40t/svgelements
- Arrives via: `svgelements` wheel
- Licence text: `cad/licenses/runtime/svgelements-1.9.6.LICENSE.txt` (sha256 897fa8febce28d8ba54db004219fde6e0ab95fdb92b54afe3c48277c1b2beebd)

SVG parsing; an ocpsvg/build123d dependency.

## svgpathtools 1.7.2

- Licence: MIT
- Copyright (c) 2015 Andrew Allan Port
- Source: https://github.com/mathandy/svgpathtools
- Arrives via: `svgpathtools` wheel
- Licence text: `cad/licenses/runtime/svgpathtools-1.7.2.LICENSE.txt` (sha256 e61b5f4e69dcb874e07ee26762113879ec326a7c98c75c9aa2c8ea5453b4e495)

SVG path maths; a build123d dependency.

## svgwrite 1.4.3

- Licence: MIT
- Copyright (c) 2012, Manfred Moitzi
- Source: https://github.com/mozman/svgwrite
- Arrives via: `svgwrite` wheel
- Licence text: `cad/licenses/runtime/svgwrite-1.4.3.LICENSE.txt` (sha256 1813a7553de927e8865345b1051c36d741b70d0e9fcab2572df673a18f936629)

SVG output for build123d's 2D exports.

## sympy 1.14.0

- Licence: BSD-3-Clause
- Copyright (c) 2006-2023 SymPy Development Team
- Source: https://github.com/sympy/sympy
- Arrives via: `sympy` wheel
- Licence text: `cad/licenses/runtime/sympy-1.14.0.LICENSE.txt` (sha256 07a5e9819f727b4986ad2829c7a29a6320d42575f720eb24d71b7fef573a0286)

Symbolic maths; a build123d dependency.

## traitlets 5.16.1

- Licence: BSD-3-Clause
- Copyright (c) 2001-, IPython Development Team
- Source: https://github.com/ipython/traitlets
- Arrives via: `traitlets` wheel
- Licence text: `cad/licenses/runtime/traitlets-5.16.1.LICENSE.txt` (sha256 2f51727d9063b54856773cb51388bdb79f2936ee4a1b692ef553d8c4201311ab)

IPython configuration system.

## trianglesolver 1.2

- Licence: MIT
- Copyright (c) 2014 Steven Byrnes
- Source: https://github.com/sbyrnes321/trianglesolver
- Arrives via: `trianglesolver` wheel
- Licence text: `cad/licenses/runtime/trianglesolver-1.2.LICENSE.txt` (sha256 f2f2c7aa22ab90d6df40406913545c14f1c38a4b4438356560c36662ae8045db)

Triangle solving; a build123d dependency. The wheel ships its LICENSE.txt as cp1252; the copy here is the same text transcoded to UTF-8 so it is readable everywhere it ships.

## typing-extensions 4.16.0

- Licence: PSF-2.0
- Copyright (c) 2001-2024 Python Software Foundation
- Source: https://github.com/python/typing_extensions
- Arrives via: `typing-extensions` wheel
- Licence text: `cad/licenses/runtime/typing-extensions-4.16.0.LICENSE.txt` (sha256 3b2f81fe21d181c499c59a256c8e1968455d6689d269aa85373bfb6af41da3bf)

Typing backports. Licensed under the Python Software Foundation License, whose full text (the CPython LICENSE, including the historical CWI and BeOpen notices) ships here.

## vtk 9.3.1

- Licence: BSD-3-Clause
- Copyright (c) 1993-2015 Ken Martin, Will Schroeder, Bill Lorensen
- Source: https://gitlab.kitware.com/vtk/vtk
- Arrives via: `vtk` wheel
- Licence text: `cad/licenses/runtime/vtk-9.3.1.LICENSE.txt` (sha256 11232448be82e0ea2c2c66219c2e36389f42249894070ee10c549ff182fc08b6)

Visualisation toolkit; pulled in by cadquery-ocp's VTK-enabled build. Its wheel carries the compiled VTK shared libraries.

## wcwidth 0.8.2

- Licence: MIT
- Copyright (c) 2014 Jeff Quast <contact@jeffquast.com>
- Source: https://github.com/jquast/wcwidth
- Arrives via: `wcwidth` wheel
- Licence text: `cad/licenses/runtime/wcwidth-0.8.2.LICENSE.txt` (sha256 70b98a95a2144eb70af8017fa8c6d95ce247e40867436e8bc649e137fe13d21a)

prompt-toolkit dependency.

## webcolors 24.8.0

- Licence: BSD-3-Clause
- Copyright (c) James Bennett, and contributors.
- Source: https://github.com/ubernostrum/webcolors
- Arrives via: `webcolors` wheel
- Licence text: `cad/licenses/runtime/webcolors-24.8.0.LICENSE.txt` (sha256 224bb9063d1204f687477a680fab945debff8cf717c629510c1d7083d9a7969a)

Colour-name parsing; a build123d dependency.

## Shipped alongside the licence texts

Files under `cad/licenses/` that are not a component's licence text but travel with the distribution. Declared in `DECLARED_SUPPORT_FILES`, so the gate demands them by name.

- `cad/licenses/README.md` (sha256 a7559d4d4a4dfd803594d636150dc25abed59bf528cf1ccfbfdbde3f91cbbc51) — explains what the directory is, how it reaches the distribution, and what to do when adding a dependency

## Excluded from the inventory

Census distributions deliberately not attributed, each with the reason. The gate refuses any OTHER census distribution that is neither inventoried above nor listed here.

**None.** Every distribution in the census is inventoried above.

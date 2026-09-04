# NOTICE — cad runtime bundle

**This file is GENERATED. Do not hand-edit it.**

Regenerate with:

    python3 cad/scripts/gen_notice.py

Licence and attribution inventory for the third-party content that ships inside the cad plugin's embedded Python runtime bundle, whose pins live in `cad/scripts/runtime-bundle.lock`. The full text of every licence below is in `cad/licenses/runtime/`, which is copied into the bundle (as `licenses/`) and into the release tarball beside the plugin binary — BSD and MIT terms require the notice, conditions and disclaimer to be provided with a binary distribution, so naming the licence here is not on its own enough.

A wheel's own metadata cannot see what it vendors: python-fcl's wheel contains compiled FCL, libccd, OctoMap and Eigen while shipping only python-fcl's LICENSE. The inventory below is therefore maintained by hand in `cad/scripts/gen_notice.py`, and its `--check` mode is the gate that keeps it honest against the lock.

Runtime pins in the lock: build123d, python-fcl

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

## Microsoft Visual C++ runtime (MSVCP140.dll and the VCRUNTIME140 pair) Visual Studio 2022 redistributable

- Licence: LicenseRef-Microsoft-VC-Redistributable
- Copyright (c) Microsoft Corporation
- Source: https://learn.microsoft.com/en-us/visualstudio/releases/2022/redistribution
- Arrives via: not a PyPI distribution
- Licence text: `cad/licenses/runtime/microsoft-vc-runtime.ATTRIBUTION.txt` (sha256 a09ab0e549aaa77c391da589fbbb865921686c3eb68a73e10c48386d60a2d953)

Windows bundle only. The python-fcl extension imports MSVCP140.dll, which python-build-standalone does not ship, so the Windows build repairs the wheel with delvewheel and the DLL travels inside the bundle instead of being resolved from the user's machine. Nothing is checked into this repository.

## Shipped alongside the licence texts

Files under `cad/licenses/` that are not a component's licence text but travel with the distribution. Declared in `DECLARED_SUPPORT_FILES`, so the gate demands them by name.

- `cad/licenses/README.md` (sha256 ab328bd04cd139c4f030a69d35c46df41fd7858b7699bde7a9ed94272dcbef85) — explains what the directory is, how it reaches the distribution, and what to do when adding a dependency

## Not yet inventoried

Lock pins whose licence trees this inventory does not yet cover. They are listed rather than omitted so the gap is visible; the gate refuses any OTHER pin that is neither inventoried nor listed here.

- `build123d` — pre-existing pin; its own licence and its transitive tree (cadquery-ocp, OCCT, and the IPython/jedi chain) are not yet inventoried.
- `cadquery-ocp` — pulled in transitively by build123d and repeated here only if pinned directly; OCCT's licence tree is not yet inventoried.

Total: 6 inventoried components, 2 pending.

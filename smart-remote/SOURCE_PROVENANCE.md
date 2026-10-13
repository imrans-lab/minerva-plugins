# Source provenance

This Rust plugin and protocol were extracted from the private ccsandbox repository at `f3bbbe35c6d206a45b2244eb885e9a2097c3d0c2`. Only `smart-remote-v2/minerva-plugin/` and `smart-remote-v2/protocol/` were retained, renamed to `smart-remote/` and `smart-remote/protocol/`. No firmware, enclosure, Docket files, unrelated paths are imported. Original source messages, authors and timestamps are retained.

An isolated `--no-local --no-hardlinks` clone was pinned before filtering with git-filter-repo 2.47.0. The original checkout and refs were untouched. Original commit messages are preserved exactly, including commit-hash references. Empty commits were pruned. Their mapping below identifies every retained source revision; the filtered branch was merged without squashing.

The authoritative protocol now lives in this repository. The sandbox protocol remains a migration snapshot until a separately reviewed source cleanup; compare it read-only with `scripts/check-protocol-sync.sh /path/to/ccsandbox/smart-remote-v2/protocol`. Every contract file must match; only the ownership README and generated Python `__pycache__` files are excluded. The one accepted documentation ownership amendment is pinned by exact source and canonical SHA-256 hashes in `scripts/protocol-owner-amendment.json`; the checker reports this retained snapshot difference explicitly and refuses any other drift. Plugin schemas are embedded from this canonical directory; Rust examples and the Python validator consume the same files. Protocol v1 wire schemas, examples and framing are unchanged. The canonical behavior document now records the owner's Minerva-owned STT/TTS ruling (comment 122); the sandbox snapshot retains the former wording until separately reviewed synchronization. Firmware integration must pass this comparison after either repository changes.

The extraction commit preserves original file contents. The following integration commit adjusts local build/test paths and repository documentation, adds repository manifest listing metadata, the repository-convention source setup and CI. The known generic Windows source-setup suffix limitation is explicitly documented under orchestrator disposition relay 2925; its host fix and script mirror remain assigned to M1b/P2. Source builds carry the protocol inside the plugin directory; the existing backend launch contract is unchanged. The branch push lane performs format/build and the repository secret scan with a 10-minute optimization target; the full Rust, real socket/stdio, live mDNS and Python example checks run by dispatch or in the isolated qualification environment. No release or marketplace advertisement is created here.

| Source commit | Filtered commit |
|---|---|
| `04fae6d3177e4e24d549dda0fc055c29a24f9241` | `a7614c3492762eab12d7ace6b7fef85f5f31ac96` |
| `234c73db28e643b0aecd39ba511a79b48d1da019` | `672805ee9e4a6bb743645c6bae2a19ff8554fb7a` |
| `36e60b52378915557cc1d0e055bf65590f84f654` | `0fb7a3c047d7c201fde64523b4ca20f50f98bf91` |
| `4b334f5e74b31bd3dc1e38195e2e9f0dbe1a89d9` | `52abd078cbac59c5315ba83213febe8a245331f9` |
| `717e903c84996cefd6d99659f7b98e58b249011e` | `bd2210087a3ba9b14ef1abdcbd0c8f66d78259e8` |
| `8abff161c46d9cc69c6b9eb45cee7a66677fcd27` | `713affb0a2c7c8d5c5e783f653a2d16add4907b9` |
| `9407cabcdfebdee8f9e9a75371d895a34112ae1c` | `c8568b81dba26f40f12f02371296cbdb07dbcb18` |
| `98e3cfbe349d55e576a7185d0825e965527f8145` | `9cfaaee64e91720c5daac99cff82c75e60209018` |
| `aa45198f8bddfffc7cc1b88817f034ff7b08bf0e` | `2708b5915378f91177c3e0d3b2b198b47fc18e89` |
| `aca0e99b89650cdff8e559dab42bcf844b34d354` | `55002852fbf58929d4d79d301f57cff572e6ab86` |
| `be173ceb72161a73c5c203c3dc76ab8cc4030fb6` | `74239c2b4cef3e56583d51f0cd36809f67d4bbd2` |
| `e5bc759b153a2e1ea6e91c5719f1908bf6d9a5ba` | `c0c0737b4a2425317e747e9546bf21dff138b124` |

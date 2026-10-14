# Synthetic Security 2 test oracle

The Python files in `espsecurity` are unchanged [ESP-IDF source](https://github.com/espressif/esp-idf/tree/8c750b088c7cd857d079c0eeb495da199b359461/tools/esp_prov), commit `8c750b088c7cd857d079c0eeb495da199b359461`, licensed Apache-2.0; see [license](../../proto/espressif/LICENSE.md). `utils.py` is the upstream convenience module renamed for this isolated fixture package; `__init__.py` is an empty package marker.

`record_security2.py` runs that official client with explicitly synthetic public inputs and independent Python AESGCM, generating `security2.rs`. The second transcript uses a short client public key to verify SRP padding. These are independently recorded client known-answer transcripts, not real-device captures. Neither the recorder nor the oracle is linked into the plugin. Python protobuf3.21.12 and cryptography41.0.7 were used to record the initial vectors. Re-run in an isolated test environment and compare the generated file.

| Fixture | Original source path | SHA-256 |
|---|---|---|
| `security.py` | `tools/esp_prov/security/security.py` | `37a88d266d730154b0b914e51b68e0e50d2565a192cedf76ac57f2743f79c58e` |
| `security2.py` | `tools/esp_prov/security/security2.py` | `bdc90f36a754a9a767aa7298bd697b7ed0ddf42777bda159d13ed646a7c39445` |
| `srp6a.py` | `tools/esp_prov/security/srp6a.py` | `6074ab48d653669b6da24525cf7b7d6ac6ab4b88e4274ae69c2df8597c2a0834` |
| `utils.py` | `tools/esp_prov/utils/convenience.py` | `fadbef74d036079ada0d7ed249ddabc26c8dd10d56aa910cfccf7ed9f7c99d01` |

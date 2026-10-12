# smart-remote-v2 Bluetooth setup (provisioning), version 1

Gives the remote its WiFi credentials, Minerva's address and a pairing token, over Bluetooth LE. Afterwards the remote reaches the plugin over the LAN protocol in `protocol.md`.
Design: Docket `smart-remote:01a12de97992`. Owner rulings 2026-10-12: the remote shows the pairing code and the user types it into Minerva; setup is entered by holding SW2 while waking.

## Basis

- Espressif unified provisioning from the pinned in-tree ESP-IDF 5.5 `wifi_provisioning` component: protocomm over NimBLE with **Security 2** (SRP6a key agreement, AES-GCM session). No custom cryptography on either side.
- Standard endpoints (`prov-session`, `prov-scan`, `prov-config`, `proto-ver`) carry the session, the WiFi scan, the WiFi credentials and connection status, exactly as Espressif defines them.
- One custom endpoint, `minerva-config`, carries Minerva's address and the token. Its payload travels inside the Security 2 session like the standard endpoints.

## Entering and leaving setup (device)

- A remote with no committed Minerva config starts in setup on every wake.
- Holding **SW2 while pressing SW1 to wake** enters setup on a provisioned remote. The existing config stays in force until a new one is committed.
- Setup is an **exclusive mode**: BLE HID is stopped first, because the provisioning transport owns NimBLE initialisation. WiFi starts only for the scan and connection test.
- The OLED shows `Setup`, the advertised name and a 6-digit pairing code.
- The code is random per setup session. It is regenerated after 3 failed session handshakes.
- Setup ends after 5 minutes without a completed session, or on a long SW1 press. Either way the remote goes to deep sleep and keeps any previous config.
- After a successful commit the remote reboots. It never resumes HID inside the same boot.

## Advertising

- Name `SR2-XXXX`, where `XXXX` is the last two bytes of the WiFi MAC in uppercase hex.
- Primary service UUID `7cfd5818-3705-4e21-8f3a-cce005338a9b`.
- Endpoint characteristics are found by their User Description descriptor (0x2901), which holds the endpoint name, not by fixed characteristic UUIDs.

## Security 2 parameters

- Username: `minerva-remote`.
- Password: the 6 decimal digits on the OLED, as ASCII.
- The device generates the salt and verifier at setup start from that code (`esp_srp_gen_salt_verifier`) and never stores the code.

## `proto-ver`

Set with `wifi_prov_mgr_set_app_info("minerva", "1", ["minerva-config"], 1)`. The plugin refuses to continue unless the `minerva` entry has version `"1"`.

## `minerva-config`

UTF-8 JSON in both directions, at most 512 bytes.

Request (plugin → device):

```json
{"v": 1, "host": "192.168.1.20", "port": 47821, "token": "<43 chars>"}
```

- `host`: an IPv4 literal or a DNS/mDNS hostname, at most 253 characters. It is the address the plugin's WebSocket listens on.
- `port`: integer 1–65535.
- `token`: 32 random bytes from the plugin, base64url without padding (43 characters). It is sent as `hello.token`.

Response (device → plugin):

```json
{"v": 1, "ok": true, "device_id": "a4cf12b03e5d"}
{"v": 1, "ok": false, "error": "bad_request"}
```

- `device_id` is the lowercase WiFi MAC, the same value later sent in `hello.device_id`.
- On `ok:true` the config is **staged in RAM, not committed**.
- Error values: `bad_request` (malformed or out of range) and `version` (unsupported `v`).

## Order of operations (plugin)

1. Scan for the service UUID and list `SR2-XXXX` devices. The user picks one and types the code from its OLED.
2. `prov-session` handshake. A wrong code fails here; the plugin reports it and lets the user retry.
3. Check `proto-ver`.
4. `minerva-config` with a freshly generated token. Keep the returned `device_id`.
5. `prov-scan`; the user chooses a network and types its password.
6. `prov-config` set, then apply. Poll status until it reports connected or failed.
   - **Connected:** the device commits WiFi credentials and the staged Minerva config to NVS together, then reboots.
   - **Failed:** the device discards the staged config and reports the failure reason. The plugin offers to retry from step 5.
7. Pairing is complete only when the remote connects over the LAN protocol and sends `hello` with that `device_id` and the new token, within 60 s of the connected status. Otherwise the plugin reports the pairing as unconfirmed.

## Plugin storage

- Per `device_id`: the SHA-256 of the token, the advertised name and the pairing time. The plaintext token is not kept after step 4.
- Re-pairing a `device_id` replaces its record, so the old token stops working.
- Removing a device in the plugin panel deletes its record. The remote's next `hello` is refused with `error{code:"auth"}`.

## Device storage

- WiFi credentials are kept by the WiFi stack.
- `host`, `port` and `token` live in NVS namespace `minerva`.
- The device never erases NVS to recover from an error.

## Open

- Token at rest on the device is plaintext NVS unless flash encryption is enabled. Flash encryption and secure boot are not yet ruled (discussion `01a08ecd92d3`, decision 10).

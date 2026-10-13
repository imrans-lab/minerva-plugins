P2b relay exit paths. Named test: `smart-remote/tests/speech_log.rs::authoritative_log_controls_cross_real_stdio_and_lan` (real plugin binary, scripted host contract, paired LAN). Physical firmware confirmation/playback and actual Minerva service/store are later integration gates. Cancellation here means link/host cancellation; there is no new device cancel-log control.

| State | Cancel | Timeout | Disconnect/reconnect | Revoke | Host EOF |
|---|---|---|---|---|---|
| Log wait | Old page wait cancelled on replacement; late result ignored | Held page yields visible error at5s; PTT bytes continue | Replacement fetches new count; old reply cannot refresh it | Host refusal visible, endpoint closes/unregisters | Real stdin EOF with outstanding mutation wait stops binary |
| Mutation | Held delete is cancelled on replacement; late receipt ignored | Held delete yields error, no retry or refresh/success claim | Successful delete refreshes page/count; old connection action never resent | Actual delete refusal closes/unregisters without retry | Real stdin EOF with held delete stops binary; no replay |

Every cell links to the named fixture below through the batch card. Page and mutation cancellation/revoke/timeout paths are exercised separately; firmware gesture confirmation itself is not asserted by this test.

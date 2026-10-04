# Signed official Docket acquisition

Build this standalone Go 1.23+ module with `GOWORK=off go build -mod=readonly .`.
Run `./docket verify-pins` to verify the official release's signed checksums against
all embedded platform pins. Run `./docket acquire /absolute/private/directory`
to acquire the host platform and print its absolute executable path. Each install
is cached at `<root>/<tag>-<target>` with a matching acquisition receipt, versioned and atomically published; failed attempts leave prior installs intact.
The root must be private (0700 on Unix). On Windows use a private subdirectory
of the user LOCALAPPDATA tree with its default user ACLs. No application is launched.

The embedded lock and publisher key pin v0.3.0-rc.18. Acquisition retains all
archive files, including native libraries and licenses. Unsupported platforms,
symlinks, unsafe paths, unsigned releases and checksum mismatches fail closed.
Downloads have time and size limits; extraction allows at most 1 GiB/10,000 entries.
Signatures are validated at their authenticated creation time, so an immutable
release remains usable after its signing key expires. Only one signature packet
is accepted. Staging older than 24 hours is cleaned; acquisitions are bounded to
ten minutes and preserve concurrent staging and prior installations.

To bump a release:
1. Confirm the official tag, release source commit and HTTPS download URL.
2. Download all three archives, SHA256SUMS, signature and publisher public key;
   verify the signature and compare archive digests with the signed checksums.
3. Update release.lock.json tag/source/URL, platform asset names, SHA256 digests
   and entrypoints, primary/signing fingerprints and the key file SHA256.
   Replace release-signing-key.asc if the publisher rotates its key.
4. Check primary/subkey expiry and revocations; renew/rotate the publisher key
   before expiry for new releases. Preserve historical release validation time.
5. Update the rc.18 fixture references in main_test.go and this README; review
   main.go's four-platform count if supported platforms change. Build, run
   verify-pins and the full fixture tests against the new signed release.

Signature verification uses ProtonMail/go-crypto v1.5.2 (BSD-3-Clause), with pinned
Cloudflare CIRCL (BSD-3-Clause) and Go x/crypto and x/sys (BSD-3-Clause), fetched
through Go modules. `go.sum` records dependency provenance; no binary is vendored.
The acquired Docket archive carries its own LICENSE and third-party notices.

Tests require `DOCKET_RELEASE_FIXTURE` pointing to the actual official three
archives, SHA256SUMS and SHA256SUMS.asc. They do not run acquired executables.

# Signed official Docket acquisition

Build this standalone Go 1.23+ module with `GOWORK=off go build -mod=readonly .`.
Run `./docket verify-pins` to verify the official release's signed checksums against
all embedded platform pins. Run `./docket acquire /absolute/private/directory`
to acquire the host platform and print its absolute executable path. Each install
is versioned and atomically published; failed attempts leave prior installs intact.
The root must be private (0700 on Unix). No application is launched.

The embedded lock and publisher key pin v0.3.0-rc.18. Acquisition retains all
archive files, including native libraries and licenses. Unsupported platforms,
symlinks, unsafe paths, unsigned releases and checksum mismatches fail closed.
Downloads have time and size limits; extraction allows at most 1 GiB/10,000 entries.
Updating a release requires updating the lock and verifying the publisher's key.

Signature verification uses ProtonMail/go-crypto v1.5.2 (MIT), with pinned
Cloudflare CIRCL (BSD-3-Clause) and Go x/crypto and x/sys (BSD-3-Clause), fetched
through Go modules. `go.sum` records dependency provenance; no binary is vendored.
The acquired Docket archive carries its own LICENSE and third-party notices.

Tests require `DOCKET_RELEASE_FIXTURE` pointing to the actual official three
archives, SHA256SUMS and SHA256SUMS.asc. They do not run acquired executables.

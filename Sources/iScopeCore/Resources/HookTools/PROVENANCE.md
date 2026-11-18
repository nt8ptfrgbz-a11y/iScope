# iScope workflow backend

The modules in `lib/` are derived from the user's `ios-hook-tools` project at
`/Users/edy/Downloads/ios-hook-tools`, integrated on 2026-11-18.

They retain its Mach-O injection, dependency validation, local signing-asset
selection, inside-out signing, final-package verification and device filtering.
The bundled version adds process-group cancellation and archive local-header
checks. `workflow.py` provides iScope's versioned JSON-lines interface, Xcode
build snapshots, target Bundle ID adaptation, progress and retryable artifacts.

No certificates, private keys, provisioning profiles, IPAs or project-specific
Hook implementations are bundled.

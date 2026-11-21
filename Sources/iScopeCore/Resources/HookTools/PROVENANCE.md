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

Standalone source compilation also reuses `lib/build.py` from the same project
(integrated 2026-11-20). The protocol supports independent source builds, dylib
injection, IPA re-signing and installation, with final artifacts published beside
the selected inputs and numbered filenames when earlier outputs exist.
Package verification also handles ditto's unflagged UTF-8 ZIP names and macOS
Unicode normalization so independently named non-ASCII dylibs can be injected.

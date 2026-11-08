# Troubleshooting Library Sync

## Plugin does not appear

Verify the exact directory structure:

```text
<koreader>/plugins/library-sync.koplugin/
  _meta.lua
  main.lua
  bookorbit_routing.lua
  grimmory_updater.lua
  providers/
    init.lua
    grimmory.lua
    bookorbit.lua
```

Common causes:

- The ZIP created a nested `library-sync.koplugin/library-sync.koplugin/` directory.
- The directory does not end in `.koplugin`.
- KOReader was backgrounded instead of fully restarted.
- The files were copied to a different KOReader installation's storage directory.
- Both `library-sync.koplugin` and the legacy `grimmory-sync.koplugin` directory are installed at the same time.

Existing legacy installs under `<koreader>/plugins/grimmory-sync.koplugin/` are still supported. New manual installs should use `library-sync.koplugin`.

## Check Lua syntax

From a system with Lua installed:

```bash
cd library-sync.koplugin
luac -p main.lua _meta.lua grimmory_updater.lua providers/*.lua
```

## Check the log

KOReader normally writes its log to:

```text
<koreader>/crash.log
```

Search for:

```text
[GrimmorySync]
grimmorysync
grimmory-sync.koplugin
library-sync.koplugin
library_sync
```

Some internal identifiers retain the old Grimmory name for compatibility even when BookOrbit is selected.

## Connection failures

Confirm that:

- The server URL is the origin, such as `https://books.example.com`, not a browser-only local address.
- The KOReader device can reach that address.
- Reverse proxies allow `/api/v1/opds` and book download requests.
- The configured OPDS username and password are OPDS credentials.
- The optional account username and password are normal server account credentials.

Normal Grimmory or BookOrbit account credentials may not authenticate the OPDS catalogue. Configure them separately only for optional API metadata and author images. If extra metadata fails behind a reverse proxy or tunnel, configure Library Sync with the public `https://` server URL.

## Useful issue details

Include the following when reporting a problem:

- KOReader version
- Device and firmware
- Library Sync version
- Selected server type
- Relevant `[GrimmorySync]` log lines
- Whether all-books sync or a restricted sync source was selected
- Approximate local and remote library sizes

## BookOrbit file-rule adapter (0.7.6; opt-in)

The opt-in adapter is experimental and disabled by default.
Its menu, help and owned errors support English and Swedish. Do not edit the
BookOrbit plugin's files or set KOReader's global `download_dir` as a workaround.
Compare the two server URLs, selected Library Sync provider, folder and filename
profiles first. A rule load/callback error, missing required category fields,
unsafe path, changed settings, unsupported BookOrbit plugin version or replaced
download hook must not silently fall back to BookOrbit's destination.

Run offline fixture contracts with Lua 5.1/LuaJIT:

```sh
lua5.1 tests/provider_contract_spec.lua
lua5.1 tests/bookorbit_routing_spec.lua
luajit tests/provider_contract_spec.lua
luajit tests/bookorbit_routing_spec.lua
lua5.1 tests/updater_release_spec.lua
luajit tests/updater_release_spec.lua
python3 scripts/verify-bookorbit-routing.py --lua lua5.1
python3 scripts/verify-bookorbit-routing.py --lua luajit
python3 scripts/package.py
```

The last two test commands download SHA-verified official source from frozen
BookOrbit 3.6.0 / 3.7.0 revisions into ignored `test-results/` (never the runtime
ZIP), then exercise real single/bulk/sheet/path-check methods with mocked
network/filesystem/widgets/transfer execution. Those four source files are
byte-identical at the two pins. These are not device timing or physical transfer
results. Automated coverage includes shared rules/naming, previews, category
enrichment, custom-rule failures, settings changes with usable Cancel, symlink
and open-file protection, native collisions/skip behavior, opt-in persistence,
other-server/format fallback and future-version/hook-conflict guards.

Before release, verify on a device using separate test books: single and bulk
EPUB/CBZ routing; preview/final/link agreement; opening the downloaded file;
existing-file Replace/Skip and collisions; mixed PDF/EPUB choices; custom tags;
cancellation, sleep/resume and restart with the toggle retained; integration off
and an unrelated server. Preserve real books, settings and reading data. Unknown
future versions require a new source review and retest before expanding support.

Local verification, 2026-11-08: the existing provider contracts and 24 new
routing cases pass with Lua 5.5 and LuaJIT; the frozen-method supplements pass
for both source pins with both interpreters. Supplement-only branches include
actual native collision/skip behavior, edition changes (including deferred
callbacks, multiple sheet lifetimes and closing before a pending callback) and
already-on-device skips. Both canonical and legacy ZIPs contain the same 12
runtime/documentation files with bytes verified against the working source.
The initial private development packaging used version 0.7.4. Release 0.7.6 also
includes the already published 0.7.5 BookOrbit HTTP-409 fallback and incomplete-
sync/Mirror protections. Device installation and physical acceptance are still
outstanding; a public release does not imply either.

Release validation also reproduces an older updater defect in its no-JSON
fallback: unescaped hyphens prevented exact ZIP-name matching, and a prefix
match could accept a checksum sidecar. 0.7.6 escapes the complete basename and
requires its closing quote. New parser contracts cover JSON and no-JSON paths,
canonical/legacy installations, both asset orders and escaped URLs. The older
published updater's normal JSON path selects the right package. If an older
installation cannot load KOReader's JSON module, install the correctly named
ZIP manually instead of relying on its defective fallback; published old
release assets are not overwritten to work around that defect.

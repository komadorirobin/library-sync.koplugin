# Troubleshooting Library Sync

## Plugin does not appear

Verify the exact directory structure:

```text
<koreader>/plugins/grimmory-sync.koplugin/
  _meta.lua
  main.lua
  grimmory_updater.lua
  providers/
    init.lua
    grimmory.lua
    bookorbit.lua
```

Common causes:

- The ZIP created a nested `grimmory-sync.koplugin/grimmory-sync.koplugin/` directory.
- The directory does not end in `.koplugin`.
- KOReader was backgrounded instead of fully restarted.
- The files were copied to a different KOReader installation's storage directory.

## Check Lua syntax

From a system with Lua installed:

```bash
cd grimmory-sync.koplugin
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
```

The internal identifiers retain the old Grimmory name for compatibility even when BookOrbit is selected.

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

# Grimmory Sync for KOReader

A KOReader plugin that syncs books from a Grimmory OPDS server to a local device library. It scans the local library, compares filenames with the remote OPDS catalogue, downloads books that are missing on the device, and can refresh existing EPUB files when metadata has changed in Grimmory.

## Features

- Recursive local library scan.
- OPDS catalogue pagination support.
- Basic-auth support for protected Grimmory instances.
- Automatic downloads for missing books.
- Manifest-based metadata refresh for existing local books by safely re-downloading only changed or previously untracked EPUB files.
- Optional automatic metadata refresh at startup or on an interval, with an opt-in OPDS timestamp trigger.
- Manual OTA update checks and installation from GitHub Releases.
- Configurable download folder and file naming profiles, including neutral defaults and optional custom path rules.
- Recent-download history with quick open from KOReader.

## Installation

Copy the plugin folder to KOReader's plugin directory:

```text
<koreader>/plugins/grimmory-sync.koplugin/
```

In this README, `<koreader>` means KOReader's user storage directory on your device, and `<library>` means the book-library folder you configure in Grimmory Sync.

The directory must contain at least:

```text
_meta.lua
main.lua
```

Restart KOReader after copying the plugin.

## Configuration

Open KOReader and go to:

```text
Menu -> Magnifying glass -> Grimmory Sync -> Configure
```

Set:

- `Server URL`, for example `http://192.168.1.100:6060`.
- `Username`, optional.
- `Password`, optional.
- `Local book path`, for example `<library>/ePubs` or another folder where KOReader can read and write books.

Credentials are stored locally in KOReader's storage as plain text because this plugin follows KOReader's simple plugin-settings style. Use it on a trusted device/network.

### Download Folder Profiles

The menu item `Download folder profile` controls where newly downloaded books are placed under the local book path:

- `Library root`: put every downloaded EPUB directly in the configured library folder.
- `Author folders`: put books under an author-sort folder.
- `Genre/series folders`: put books under the first Grimmory genre/tag, then under the series when present.
- `Custom rules file`: read rules from `<koreader>/grimmory_sync_path_rules.lua`, or another path configured from the same menu.
- `Swedish genre example`: an example layout for Swedish tags such as Manga, Serier, Light novels, Fiktion, Facklitteratur, and Lyrik.

New installations default to `Library root`. Existing installations without a saved folder profile are treated as `Swedish genre example` to avoid moving an established personal library layout. Older saved personal-layout settings are migrated automatically.

Custom rules may return either a Lua table or a function. Table rules can match `genre`/`genres`, `tag`/`tags`, `author`/`authors`, or a custom `when(book, helpers)` function. Grimmory OPDS categories are exposed as the same genre/tag list. A table-based example is included in `examples/path_rules.lua`.

### Download File Naming

The menu item `Download file naming` controls the filename used for newly downloaded EPUB files:

- `Grimmory file name`: use Grimmory's original source filename when available.
- `Grimmory Sync default`: use `Author, Firstname - Title.epub`.
- `Calibre title-authors`: use `Title - Authors.epub`.

New installations default to `Grimmory file name`. Existing installations without a saved filename profile keep `Grimmory Sync default` to avoid silently changing an established local library layout.

Duplicate detection is broader than the selected filename profile. Grimmory Sync checks Grimmory's original filename, the current default format, Calibre title-authors format, Calibre-style article sorting such as `Apollo Murders, The - Chris Hadfield.epub`, underscore variants, and title-only fallback names before deciding a book is missing.

### Sync Source

The menu item `Select shelf to sync` controls which Grimmory OPDS feed is used as the remote source:

- `All books (default)`: sync from Grimmory's full OPDS catalogue.
- Personal shelves: sync only books from a selected Grimmory shelf.
- Magic shelves: sync only books from a selected Grimmory dynamic shelf.

The selected sync source applies to both `Sync missing books` and `Refresh existing metadata`. For example, if a Manga magic shelf is selected, metadata refresh only considers local books that can be matched against that shelf's OPDS feed. Switch back to `All books (default)` to refresh against the full catalogue.

## Usage

To download books that exist in Grimmory but are missing locally, run:

```text
Menu -> Magnifying glass -> Grimmory Sync -> Sync missing books
```

The plugin will:

1. Scan local books under the configured local path.
2. Fetch the Grimmory OPDS catalogue.
3. Compare remote books to local filenames.
4. Download missing books into the configured library path.

To refresh descriptions and other metadata that Grimmory has written into existing EPUB files, run:

```text
Menu -> Magnifying glass -> Grimmory Sync -> Refresh existing metadata
```

This replaces matched local EPUB files with freshly downloaded copies from Grimmory when their remote metadata signature has changed. The first run creates `grimmory_sync_manifest.lua` and may refresh all matched books once; later runs skip unchanged books. The replacement is conservative: the plugin downloads to a temporary file, verifies that it is not empty, backs up the existing file, and only then moves the new file into place.

The currently open book is skipped during metadata refresh so KOReader is not reading from a file while Grimmory Sync replaces it. Close the book or open another book, then run refresh again if the skipped book also needs an update.

To refresh only one EPUB, long-press it in KOReader's file browser and choose:

```text
Refresh Grimmory metadata
```

When a book is open, use:

```text
Menu -> Magnifying glass -> Grimmory Sync -> Refresh open book metadata
```

KOReader must close the open book before its EPUB can be replaced safely. Grimmory Sync asks for confirmation, closes the book, returns to the file browser, and refreshes only that file.

### SimpleUI Quick Actions

SimpleUI users can add Grimmory Sync shortcuts from SimpleUI's `System Actions` picker:

- `Grimmory Sync: Sync missing books`
- `Grimmory Sync: Refresh existing metadata`
- `Grimmory Sync: Refresh open book metadata`

The older SimpleUI `Plugin` shortcut entry still opens `Sync missing books` for backwards compatibility.

### Automatic Metadata Refresh

Automatic metadata refresh is off by default. Enable it from:

```text
Menu -> Magnifying glass -> Grimmory Sync -> Automatic metadata refresh
```

Available options:

- `Check at startup`: run one automatic metadata refresh shortly after KOReader starts.
- `Check interval`: run automatic checks while KOReader is awake, for example every 6 or 12 hours.
- `Use OPDS updated timestamp as refresh trigger`: also refresh a matched book when Grimmory's OPDS `<updated>` timestamp for that book changes.

Automatic checks scan the local library and contact Grimmory, so they can use more battery than manual-only syncing. The interval timer is cancelled while KOReader is suspended and restarted on resume.

By default, automatic refresh uses the same stable metadata signature as manual refresh. The OPDS timestamp trigger is opt-in because it can catch server-side EPUB rewrites that are not visible in the stable metadata fields, but it may also refresh books after other Grimmory-side changes such as rescans or internal updates.

### Bookshelf Integration

Metadata refresh can also sync Grimmory author photos into the separate Bookshelf plugin's default author image library:

```text
<local book path>/.bookshelf-images/authors/
```

This is intended for KOReader's Bookshelf plugin, which reads author images from its own image-library folders. Grimmory Sync only writes compatible image files there; Bookshelf remains responsible for displaying them.

This integration is off by default for new installations. Enable it if you use the Bookshelf plugin:

```text
Menu -> Magnifying glass -> Grimmory Sync -> Bookshelf integration -> Sync Bookshelf author images during metadata refresh
```

To update the plugin directly from KOReader, run:

```text
Menu -> Magnifying glass -> Grimmory Sync -> Check for updates
```

The updater checks the latest GitHub release, downloads `grimmory-sync.koplugin.zip`, extracts it over the installed plugin folder, and asks you to restart KOReader.

Books are placed according to the selected download folder profile and named according to the selected download file naming profile.

## Notes

- The current download implementation prefers EPUB acquisition links.
- OPDS acquisition links without an EPUB MIME type are accepted when they still look like Grimmory book download links; skipped OPDS entries are logged with their title and link details.
- Local matching is filename-based and intentionally fuzzy around common punctuation and accents.
- Large missing-book syncs yield between downloads so KOReader's UI can update during long library migrations.
- Metadata refresh uses `grimmory_sync_manifest.lua` and compares stable metadata such as title, author, series, tags, description, and Hardcover IDs when available from Grimmory's authenticated book API. If enabled, the OPDS timestamp trigger also compares each book entry's `<updated>` value.
- `Grimmory file name` uses the authenticated Book API filename when available, with OPDS filename data as a fallback.
- Bookshelf author image sync uses Grimmory's authenticated `/api/v1/authors` and `/api/v1/media/author/{id}/photo` endpoints, and writes exact/slugged Bookshelf-compatible filenames.
- The plugin UI uses English source strings wrapped with KOReader's gettext helper, so translations can be added without changing the Lua code.
- OTA updates require a release asset named `grimmory-sync.koplugin.zip`.
- Custom folder placement should live outside the plugin folder so OTA updates do not overwrite it.
- KOReader must have network access to the Grimmory server.
- Existing `booklore_sync_settings.txt` and `booklore_sync_history.lua` files are read as legacy fallbacks, but new saves use `grimmory_sync_*` files.

## Troubleshooting

See [DEBUG.md](DEBUG.md) and [INSTALL.md](INSTALL.md) for device-specific setup and debugging notes.

KOReader logs are usually in:

```text
<koreader>/crash.log
```

Search for:

```text
[GrimmorySync]
```

## License

MIT

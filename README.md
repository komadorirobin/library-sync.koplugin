# Grimmory Sync for KOReader

A KOReader plugin that syncs books from a Grimmory OPDS server to a local device library. It scans the local library, compares filenames with the remote OPDS catalogue, downloads books that are missing on the device, and can refresh existing EPUB files when metadata has changed in Grimmory.

## Features

- Recursive local library scan.
- OPDS catalogue pagination support.
- Basic-auth support for protected Grimmory instances.
- Automatic downloads for missing books.
- Manifest-based metadata refresh for existing local books by safely re-downloading only changed or previously untracked EPUB files.
- Manual OTA update checks and installation from GitHub Releases.
- Configurable download folder profiles, including neutral defaults and optional custom path rules.
- Recent-download history with quick open from KOReader.

## Installation

Copy the plugin folder to KOReader's plugin directory:

```text
/storage/emulated/0/koreader/plugins/grimmory-sync.koplugin/
```

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
- `Local book path`, default `/storage/emulated/0/ePubs`.

Credentials are stored locally in KOReader's storage as plain text because this plugin follows KOReader's simple plugin-settings style. Use it on a trusted device/network.

### Download Folder Profiles

The menu item `Download folder profile` controls where newly downloaded books are placed under the local book path:

- `Library root`: put every downloaded EPUB directly in the configured library folder.
- `Author folders`: put books under an author-sort folder.
- `Genre/series folders`: put books under the first Grimmory genre/tag, then under the series when present.
- `Custom rules file`: read rules from `/storage/emulated/0/koreader/grimmory_sync_path_rules.lua`, or another path configured from the same menu.
- `Swedish genre example`: an example layout for Swedish tags such as Manga, Serier, Light novels, Fiktion, Facklitteratur, and Lyrik.

New installations default to `Library root`. Existing installations without a saved folder profile are treated as `Swedish genre example` to avoid moving an established personal library layout. Older saved personal-layout settings are migrated automatically.

Custom rules may return either a Lua table or a function. Table rules can match `genre`/`genres`, `tag`/`tags`, `author`/`authors`, or a custom `when(book, helpers)` function. Grimmory OPDS categories are exposed as the same genre/tag list. A table-based example is included in `examples/path_rules.lua`.

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

Downloaded files are named as:

```text
Author, Firstname - Title.epub
```

Books are placed according to the selected download folder profile.

## Notes

- The current download implementation prefers EPUB acquisition links.
- Local matching is filename-based and intentionally fuzzy around common punctuation and accents.
- Metadata refresh uses `grimmory_sync_manifest.lua` and compares stable metadata such as title, author, series, tags, description, and Hardcover IDs when available from Grimmory's authenticated book API.
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
/storage/emulated/0/koreader/crash.log
```

Search for:

```text
[GrimmorySync]
```

## License

MIT

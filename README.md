# Grimmory Sync for KOReader

A KOReader plugin that syncs books from a Grimmory OPDS server to a local device library. It scans the local library, compares filenames with the remote OPDS catalogue, downloads books that are missing on the device, and can refresh existing EPUB files when metadata has changed in Grimmory.

## Features

- Recursive local library scan.
- OPDS catalogue pagination support.
- Basic-auth support for protected Grimmory instances.
- Automatic downloads for missing books.
- Manifest-based metadata refresh for existing local books by safely re-downloading only changed or previously untracked EPUB files.
- Manual OTA update checks and installation from GitHub Releases.
- Folder placement based on Grimmory genres/tags, including Manga, Serier, Light novels, Fiktion, Facklitteratur, and Lyrik.
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
Menu -> Tools -> Grimmory Sync -> Configure
```

Set:

- `Server URL`, for example `http://192.168.1.100:6060`.
- `Username`, optional.
- `Password`, optional.
- `Local book path`, default `/storage/emulated/0/ePubs`.

Credentials are stored locally in KOReader's storage as plain text because this plugin follows KOReader's simple plugin-settings style. Use it on a trusted device/network.

## Usage

To download books that exist in Grimmory but are missing locally, run:

```text
Menu -> Tools -> Grimmory Sync -> Sync missing books
```

The plugin will:

1. Scan local books under the configured local path.
2. Fetch the Grimmory OPDS catalogue.
3. Compare remote books to local filenames.
4. Download missing books into the configured library path.

To refresh descriptions and other metadata that Grimmory has written into existing EPUB files, run:

```text
Menu -> Tools -> Grimmory Sync -> Refresh existing metadata
```

This replaces matched local EPUB files with freshly downloaded copies from Grimmory when their remote metadata signature has changed. The first run creates `grimmory_sync_manifest.lua` and may refresh all matched books once; later runs skip unchanged books. The replacement is conservative: the plugin downloads to a temporary file, verifies that it is not empty, backs up the existing file, and only then moves the new file into place.

Metadata refresh can also sync Grimmory author photos into Bookshelf's default author image library:

```text
<local book path>/.bookshelf-images/authors/
```

This is enabled by default and can be toggled from:

```text
Menu -> Tools -> Grimmory Sync -> Sync author images during metadata refresh
```

To update the plugin directly from KOReader, run:

```text
Menu -> Tools -> Grimmory Sync -> Check for updates
```

The updater checks the latest GitHub release, downloads `grimmory-sync.koplugin.zip`, extracts it over the installed plugin folder, and asks you to restart KOReader.

Downloaded files are named as:

```text
Author, Firstname - Title.epub
```

Books are placed into subfolders according to tags/genres returned by the OPDS feed.

## Notes

- The current download implementation prefers EPUB acquisition links.
- Local matching is filename-based and intentionally fuzzy around common punctuation and accents.
- Metadata refresh uses `grimmory_sync_manifest.lua` and compares OPDS metadata markers such as `updated`, `published`, download URL, title, author, series, tags, and description.
- Author image sync uses Grimmory's authenticated `/api/v1/authors` and `/api/v1/media/author/{id}/photo` endpoints, and writes exact/slugged Bookshelf-compatible filenames.
- OTA updates require a release asset named `grimmory-sync.koplugin.zip`.
- The folder placement rules are tailored for a Swedish personal library layout. Adjust `generateTargetPath()` if your taxonomy differs.
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

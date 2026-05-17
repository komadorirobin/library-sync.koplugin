# Booklore Sync for KOReader

A KOReader plugin that syncs books from a Booklore/Grimmory OPDS server to a local device library. It scans the local library, compares filenames with the remote OPDS catalogue, and downloads books that are missing on the device.

## Features

- Recursive local library scan.
- OPDS catalogue pagination support.
- Basic-auth support for protected Booklore/Grimmory instances.
- Automatic downloads for missing books.
- Folder placement based on Booklore genres/tags, including Manga, Serier, Light novels, Fiktion, Facklitteratur, and Lyrik.
- Recent-download history with quick open from KOReader.

## Installation

Copy the plugin folder to KOReader's plugin directory:

```text
/storage/emulated/0/koreader/plugins/booklore-sync.koplugin/
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
Menu -> Tools -> Booklore Sync -> Configure
```

Set:

- `Server URL`, for example `http://192.168.1.100:6060`.
- `Username`, optional.
- `Password`, optional.
- `Local book path`, default `/storage/emulated/0/ePubs`.

Credentials are stored locally in KOReader's storage as plain text because this plugin follows KOReader's simple plugin-settings style. Use it on a trusted device/network.

## Usage

Run:

```text
Menu -> Tools -> Booklore Sync -> Sync now
```

The plugin will:

1. Scan local books under the configured local path.
2. Fetch the Booklore/Grimmory OPDS catalogue.
3. Compare remote books to local filenames.
4. Download missing books into the configured library path.

Downloaded files are named as:

```text
Author, Firstname - Title.epub
```

Books are placed into subfolders according to tags/genres returned by the OPDS feed.

## Notes

- The current download implementation prefers EPUB acquisition links.
- Local matching is filename-based and intentionally fuzzy around common punctuation and accents.
- The folder placement rules are tailored for a Swedish personal library layout. Adjust `generateTargetPath()` if your taxonomy differs.
- KOReader must have network access to the Booklore/Grimmory server.

## Troubleshooting

See [DEBUG.md](DEBUG.md) and [INSTALL.md](INSTALL.md) for device-specific setup and debugging notes.

KOReader logs are usually in:

```text
/storage/emulated/0/koreader/crash.log
```

Search for:

```text
[BookloreSync]
```

## License

MIT

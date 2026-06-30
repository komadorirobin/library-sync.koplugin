# Library Sync for KOReader

Library Sync mirrors EPUB books and metadata from a Grimmory or BookOrbit server into a local KOReader library. It scans local files, compares them with a selected OPDS catalogue, downloads missing books, and can safely replace existing EPUB files when server metadata changes.

The project and plugin directory retain the historical name `grimmory-sync.koplugin` so existing installations and OTA updates continue to work.

## Features

- Grimmory and BookOrbit server providers.
- Recursive local EPUB scanning and fuzzy duplicate detection.
- Paginated OPDS catalogue support with Basic authentication.
- Downloads for books missing on the device.
- Safe, manifest-based metadata refresh for existing EPUB files.
- Optional automatic metadata refresh at startup or on an interval.
- Configurable folder routing and file naming.
- Bookshelf-compatible author image downloads.
- SimpleUI actions and recent-download history.
- Manual OTA updates from GitHub Releases.

## Server Support

| Feature | Grimmory | BookOrbit |
| --- | --- | --- |
| All-books OPDS sync | Yes | Yes |
| Restricted sync sources | Shelves and Magic Shelves | Libraries, Collections, and SmartScopes |
| Extra genres, tags, and Hardcover IDs | Grimmory API | BookOrbit API |
| Bookshelf author images | Yes | Yes |
| Reading progress and highlight sync | Not handled | Use BookOrbit's official KOReader plugin |

Library Sync complements BookOrbit's official KOReader plugin. Library Sync handles book delivery, local file organization, metadata replacement, and Bookshelf images. BookOrbit's plugin handles progress, reading sessions, ratings, and highlights.

## Installation

Copy the complete plugin directory to:

```text
<koreader>/plugins/grimmory-sync.koplugin/
```

The directory must contain at least:

```text
_meta.lua
main.lua
providers/
```

Restart KOReader. The plugin appears under:

```text
Menu -> Magnifying glass -> Library Sync
```

`<koreader>` means KOReader's user storage directory. `<library>` below means the local book directory configured in Library Sync.

## Configuration

Open:

```text
Menu -> Magnifying glass -> Library Sync -> Configure
```

Then configure:

1. `Library server`: Grimmory or BookOrbit.
2. `Server URL`: the server origin, for example `http://192.168.1.100:6060`. The full `/api/v1/opds` URL shown by BookOrbit is also accepted.
3. OPDS username and password.
4. Optional server account credentials for extra metadata and author images.
5. The local book path where KOReader may read and write files.

Existing installations are automatically treated as Grimmory installations. Their server URL, credentials, local path, routing profile, file naming, selected shelf, manifest, and history remain valid. When upgrading from older releases, existing Grimmory OPDS credentials are copied into the new API credential fields once so installations that used one shared login continue to work.

### Grimmory Credentials

Grimmory can use separate credentials for OPDS and its normal API:

- `Grimmory KOReader Sync username/password`: configure these under Grimmory's user settings. They are used for OPDS catalogue browsing and book downloads.
- `Grimmory account username/password`: optional normal Grimmory account credentials. They enable API metadata such as series, genres, tags, Hardcover IDs, original filenames, and Bookshelf author images.

If your Grimmory OPDS and account credentials are the same, enter the same values in both places. If Grimmory is exposed through a reverse proxy or tunnel that enforces HTTPS, use the public `https://` server URL in Library Sync.

### BookOrbit Credentials

BookOrbit uses two separate account types:

- `OPDS username/password`: create these under BookOrbit's OPDS settings. They are required for catalogue browsing and book downloads.
- `BookOrbit account username/password`: optional normal BookOrbit credentials. They enable API metadata such as genres, tags, Hardcover IDs, and Bookshelf author images.

Missing-book sync and basic metadata refresh work with OPDS credentials alone. Users who authenticate to BookOrbit exclusively through OIDC may need a local BookOrbit password before the optional API features can be used.

Credentials are stored as plain text in KOReader's platform-specific `settings/` directory. Use the plugin on a trusted device and network.

## Download Folder Profiles

`Download folder profile` controls where new books are stored below the local book path:

- `Library root`: place all EPUB files directly in the library directory.
- `Author folders`: organize books under author-sort names.
- `Genre/series folders`: organize books by the first genre or tag, then series.
- `Custom rules file`: load custom Lua rules from `grimmory_sync_path_rules.lua` or another configured path.
- `Swedish genre example`: retain the bundled example for Swedish library tags.

New installations default to `Library root`. Existing installations without a saved profile retain the earlier Swedish example behavior to avoid moving an established library layout.

Custom rules may match `genre`/`genres`, `tag`/`tags`, `author`/`authors`, or use a custom `when(book, helpers)` function. Server API genres and tags require the optional account credentials. See [examples/path_rules.lua](examples/path_rules.lua).

## Download File Naming

`Download file naming` controls names for newly downloaded files:

- `Server file name`: use Grimmory's original filename when available. BookOrbit's OPDS filename convention is `Title - Author.epub`.
- `Library Sync default`: use `Author, Firstname - Title.epub`.
- `Calibre title-authors`: use `Title - Authors.epub`.

New installations default to `Server file name`. Existing installations without a saved filename profile retain the former default naming behavior.

Duplicate detection is broader than the selected naming profile. It checks server names, Library Sync names, Calibre names, article-sorted names such as `Apollo Murders, The - Chris Hadfield.epub`, underscore variants, and title-only fallbacks.

## Sync Sources

Open `Select sync source` to restrict both missing-book sync and metadata refresh.

Grimmory exposes:

- All books
- Shelves
- Magic Shelves

BookOrbit exposes:

- All books
- Libraries
- Collections
- SmartScopes

Select `All books (default)` before a full-library refresh.

## Usage

To download missing books:

```text
Menu -> Magnifying glass -> Library Sync -> Sync missing books
```

To replace matched local EPUB files when metadata has changed:

```text
Menu -> Magnifying glass -> Library Sync -> Refresh existing metadata
```

The first metadata refresh records the current state in `grimmory_sync_manifest.lua` and may refresh previously untracked books once. Later runs skip unchanged books. Replacements are downloaded to a temporary file, checked for non-zero size, and moved into place only after the existing file has been backed up.

The currently open book is skipped. To refresh one EPUB, long-press it in KOReader's file browser and choose `Refresh server metadata`. To refresh the open book, use `Refresh open book metadata`; Library Sync will ask before closing it.

## SimpleUI Actions

SimpleUI users can add these actions from the `System Actions` picker:

- `Library Sync: Sync missing books`
- `Library Sync: Refresh existing metadata`
- `Library Sync: Refresh open book metadata`

The internal action and event IDs retain their historical `grimmory_*` names for compatibility.

## Automatic Metadata Refresh

Automatic refresh is off by default. Available options are:

- `Check at startup`
- `Check interval`
- `Use OPDS updated timestamp as refresh trigger`

Automatic checks scan the local library and contact the server, so they consume more battery than manual-only use. Timers stop while KOReader is suspended and restart on resume.

The stable signature compares title, author, series, categories, description, and available Hardcover identifiers. The optional OPDS timestamp trigger may catch server-side file rewrites, but it may also react to rescans or internal server updates that were not direct metadata edits.

## Bookshelf Integration

Library Sync can write author images for the separate Bookshelf plugin to:

```text
<library>/.bookshelf-images/authors/
```

Enable it under:

```text
Library Sync -> Bookshelf integration -> Sync Bookshelf author images during metadata refresh
```

Existing images are skipped. Grimmory uses its author media API, and BookOrbit uses its paginated authors API and full author-image endpoint. These API-backed image features require the optional normal server account credentials.

## OTA Updates

Use `Library Sync -> Check for updates`. The updater still downloads `grimmory-sync.koplugin.zip` from this repository so existing installations remain on the same update channel.

## Storage and Compatibility

Settings, history, and metadata manifests are stored in KOReader's platform-specific `settings/` directory. Existing Android-root `grimmory_sync_*` files and older `booklore_sync_*` files remain readable migration fallbacks.

Custom rules should remain outside the plugin directory so OTA updates cannot overwrite them.

## Troubleshooting

See [DEBUG.md](DEBUG.md) and [INSTALL.md](INSTALL.md). KOReader logs are normally available at:

```text
<koreader>/crash.log
```

Search for the retained internal log tag:

```text
[GrimmorySync]
```

## License

MIT

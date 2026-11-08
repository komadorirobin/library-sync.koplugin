package.path = "./?.lua;./?/init.lua;" .. package.path
local function object() return { new = function(_, opts) return opts or {} end } end
for _, name in ipairs({ "ui/widget/infomessage", "ui/widget/confirmbox", "ui/widget/inputdialog",
    "ui/widget/buttondialog", "ui/widget/container/widgetcontainer" }) do package.preload[name] = object end
package.preload.gettext = function() return function(s) return s end end
package.preload.dump = function() return function() return "{}" end end
package.preload.grimmory_updater = function() return {} end
local messages, pending, written, transfers, links, opened = {}, {}, {}, {}, {}, {}
local metadata_calls, rule_reads, saves = 0, 0, 0
local files, dirs, symlinks = {}, { ["/library"] = true }, {}
local base_version = os.getenv("BOOKORBIT_PLUGIN_VERSION") or "2.2.0"
local language, version = "en", base_version
G_reader_settings = {
    readSetting = function(_, key) if key == "language" then return language end; if key == "download_dir" then return "/native" end end,
    saveSetting = function() error("must not change global settings") end,
}
local UI = {
    show = function(_, widget) messages[#messages + 1] = widget.text end,
    nextTick = function(_, fn) pending[#pending + 1] = fn end,
    scheduleIn = function(_, _, fn) pending[#pending + 1] = fn end,
    tickAfterNext = function(_, fn) pending[#pending + 1] = fn end,
}
package.preload["ui/uimanager"] = function() return UI end
package.preload.logger = function() return { info = function() end, warn = function() end, err = function() end } end
package.preload.pluginloader = function() return { getPluginInstance = function() return { PLUGIN_VERSION = version } end } end
package.preload["libs/libkoreader-lfs"] = function() return {
    attributes = function(path, field)
        local a = files[path] or (dirs[path] and { mode = "directory" })
        return a and (field and a[field] or a)
    end,
    symlinkattributes = function(path, field) return symlinks[path] and "link" or nil end,
} end
local function makePath(path) dirs[path] = true; written[#written + 1] = path; return true end
local function inside(root, path)
    if type(path) ~= "string" or path:sub(1, #root + 1) ~= root .. "/" then return false end
    for part in path:gmatch("[^/]+") do if part == ".." or part == "." then return false end end
    for link in pairs(symlinks) do if path == link or path:sub(1, #link + 1) == link .. "/" then return false end end
    return true
end
package.preload.util = function() return {
    makePath = makePath, getSafeFilename = function(s) return s:gsub("[/\\]", " ") end,
    partialMD5 = function(path) return "hash" end,
} end
package.preload["ffi/util"] = function() return { template = function(s, ...) local args = {...}; return (s:gsub("%%(%d)", function(n) return tostring(args[tonumber(n)]) end)) end } end
package.preload.bookorbit_transfer_policy = function() return {} end
package.preload.bookorbit_transfer_progress = function() return {} end
package.preload.bookorbit_download_transfer = function() return {
    isInsideRoot = inside, sweepStale = function() end,
    run = function(opts)
        assert(inside(opts.root, opts.destination), "native transfer received wrong root/path")
        transfers[#transfers + 1] = { root = opts.root, path = opts.destination }
        files[opts.destination] = { mode = "file", size = 10 }
        return true, nil, { hash = "hash" }
    end,
} end
package.preload.bookorbit_delivery = function() return { key = function() return "account" end } end
package.preload.bookorbit_download_root = function() return { get = function() return "/native" end } end
package.preload.bookorbit_state_manager = function() return {
    applyLibraryVersion = function() end, linkFile = function(_, _, _, path) links[#links + 1] = path end,
} end
local NativeUtil = {
    safeFilenameBase = function(d) return d.title .. " - " .. table.concat(d.authors or {}, ", ") end,
    formatBytes = function() return "10 B" end, cloneParams = function(p) return p end,
    shortText = function(s) return s end, isSupportedFormat = function() return true end,
}
package.preload.bookorbit_catalog_util = function() return NativeUtil end
for _, name in ipairs({"bookorbit_bulk_checkpoint", "bookorbit_capabilities"}) do package.preload[name] = function() return {} end end
package.preload.bookorbit_toast = function() return { show = function() end, error = function(s) messages[#messages + 1] = s end } end

local Dialog = {}
function Dialog.open(opts)
    opts.closed = false
    Dialog.last_page = opts
    opts.close = function(self) self.closed = true; if self.on_close then self.on_close(self) end end
    opts.refresh = function(self) self.build(self, 600, 800) end
    opts:refresh()
    return opts
end
package.preload.bookorbit_dialog_ui = function() return Dialog end
local Sheet = {}
function Sheet.reporter(page) return {
    progress = function() end,
    finished = function(ok, err, path) page.result = { ok = ok, err = err, path = path } end,
} end
function Sheet.open(catalog, detail, opts)
    opts = opts or {}
    local editions = {}
    for _, file in ipairs(detail.files) do editions[#editions + 1] = {file = file} end
    return Dialog.open{
        name = "bookorbit_download_sheet", catalog = catalog, detail = detail, editions = editions, choice = 1,
        filename = opts.filename,
        build = function(page)
            local file = page.editions[page.choice].file
            page.preview = {catalog:getLocalDownloadPreview(page.filename or NativeUtil.safeFilenameBase(page.detail), file.format, file.devicePath, page.filename ~= nil)}
        end,
        on_action = function(page, action)
            if action.kind == "cancel" or action.kind == "close" then page:close(); return end
            if action.kind == "read" then opened[#opened + 1] = "read"; return end
            if action.kind == "edition" then page.choice = action.index; page:refresh(); return end
            local file = page.editions[page.choice].file
            if action.kind == "start" then
                local path = catalog:getLocalDownloadPath(NativeUtil.safeFilenameBase(page.detail), file.format, file.devicePath)
                catalog:downloadFile(path, page.detail, file)
            end
        end,
    }
end
package.preload.bookorbit_download_sheet = function() return Sheet end

local Catalog = {}
local native_root = function() return "/native" end
function Catalog:getCurrentDownloadDir() return native_root() end
function Catalog:chooseDownloadDir() saves = saves + 1 end
function Catalog:getLocalDownloadPath(_, ext, path) return self:getCurrentDownloadDir() .. "/" .. (path or "file." .. ext) end
function Catalog:getLocalDownloadPreview(_, ext, path)
    local name = path and path:match("([^/]+)$") or "file." .. ext
    local parent = path and path:match("^(.+)/[^/]+$")
    return self:getCurrentDownloadDir() .. (parent and "/" .. parent or ""), name:sub(1, -#ext - 2)
end
function Catalog:downloadDefaultFile(detail, file)
    return self:checkDownloadFile(self:getLocalDownloadPath(detail.title, file.format, file.devicePath), detail, file)
end
function Catalog:showDownloadOptions(detail) return Sheet.open(self, detail) end
function Catalog:showDownloadDialog(detail) return Sheet.open(self, detail) end
function Catalog:checkDownloadFile(path, detail, file) return self:downloadFile(path, detail, file) end
function Catalog:downloadFile(path, detail, file)
    return require("bookorbit_download_transfer").run{ root = self:getCurrentDownloadDir(), destination = path }
end
function Catalog:bulkResolveDestination(ctx, detail, file)
    return self:getLocalDownloadPath(detail.title, file.format, file.devicePath)
end
function Catalog:bulkChooseFile(detail) return detail.files and detail.files[1] end
function Catalog:bulkProcessBook(ctx, book)
    local file = book.files[1]
    local path = self:bulkResolveDestination(ctx, book, file, book.id)
    return self:bulkDownloadFile(ctx, book, file, path, book.id)
end
function Catalog:bulkDownloadFile(ctx, book, file, path)
    return require("bookorbit_download_transfer").run{ root = self:getCurrentDownloadDir(), destination = path }
end
function Catalog:bulkSummary() return "Summary" end
function Catalog:bulkRecordFailure(ctx) ctx.failed = (ctx.failed or 0) + 1 end
function Catalog:bulkShowStatus() end
function Catalog:supportedFiles(detail) return detail.files end
function Catalog:onDeviceFilePath() end
function Catalog:nextDownloadFile(files_) return files_[1] end
function Catalog:nextDownloadGeneration() self.download_generation = (self.download_generation or 0) + 1; return self.download_generation end
function Catalog:runOffThread(fn) return fn() end
function Catalog:refreshOnDevice() end
function Catalog:showWriteError(err) error(tostring(err)) end
function Catalog:showRetry(err) error(tostring(err)) end
function Catalog:bulkExistingPolicy() return { id = "skip" } end
function Catalog:isOnDevice() return false end
function Catalog:bulkShowStatus() end
function Catalog:bulkQueueLink(ctx, item) links[#links + 1] = item.file end
function Catalog:bulkQueueMatch(ctx, item) links[#links + 1] = item.file end
function Catalog:cachedThumbnailPath() end
function Catalog:errorText(err) return tostring(err) end
function Catalog:openDownloadedFile(path) opened[#opened + 1] = path end
function Catalog:fetchDeliveryBook(id, variant) return self.client:catalogBook(id, variant) end
function Catalog:fetch(_, fn) return fn() end
function Catalog:runConnected(fn)
    if self.defer_connected then pending[#pending + 1] = fn; return end
    return fn()
end

-- Optional frozen, real BookOrbit mixins replace the fixture methods. No native
-- code is shipped in Library Sync. Primitive UI/network/filesystem remain mocks.
local native_dir = os.getenv("BOOKORBIT_NATIVE_DIR")
if native_dir then
    local transfer = dofile(native_dir .. "/bookorbit_download_transfer.lua")
    local fake_transfer = require("bookorbit_download_transfer")
    fake_transfer.isInsideRoot = transfer.isInsideRoot
    dofile(native_dir .. "/bookorbit_catalog_download.lua").install(Catalog)
    dofile(native_dir .. "/bookorbit_catalog_bulk_download.lua").install(Catalog)
    Catalog.fetchDeliveryPreference = function(_, variant) return variant end
    -- Keep the real duplicate/collision/process logic; the queues need no UI.
    Catalog.bulkPreferredFormats = function() return {"epub", "cbz"} end
    Catalog.bulkShowStatus = function() end
    Catalog.bulkQueueLink = function(_, _, item) links[#links + 1] = item.file end
    Catalog.bulkQueueMatch = function(_, _, item) links[#links + 1] = item.file end
    local painting
    local function widget() return { getSize = function() return {w = 400, h = 100} end, free = function() end } end
    package.preload.bookorbit_board_metrics = function() return { INK = {g4 = 4}, px = function(n) return n end, layoutW = function() return 600 end } end
    package.preload.bookorbit_board_ui = function() return { text = widget, vstack = widget, hstack = widget, space = widget, spread = widget, bar = widget } end
    package.preload.bookorbit_menu_ui = function() return {
        rowsIn = function(w) return w end, group = widget, pill = widget, check = widget,
        row = function(_, opts)
            if opts.label == "Folder" then painting.preview = {opts.sub} end
            if opts.label == "File name" then painting.preview[2] = opts.sub:gsub("%.[^.]+$", "") end
            return widget()
        end,
    } end
    package.preload.bookorbit_book_peek = function() return {folderLabel = function(s) return s end} end
    Dialog.sheet = function(page, sw, sh, build)
        painting = page
        build(sw)
        painting = nil
        page.panel_rect = {y = 10, h = 500}
        return widget()
    end
    Dialog.bookHead, Dialog.section, Dialog.warn, Dialog.pillRow = widget, widget, widget, widget
    Sheet = dofile(native_dir .. "/bookorbit_download_sheet.lua")
    package.loaded.bookorbit_download_sheet = Sheet
end
package.loaded.bookorbit_catalog = Catalog
local plugin = dofile("main.lua")
local owner = setmetatable({
    server_type = "bookorbit", server_url = "https://books.example/api/v1/opds", local_path = "/library",
    routing_profile = "swedish_genre_example", filename_profile = "sync_default", bookorbit_download_rules = true,
    ensureDirectory = function(_, path) return makePath(path) end,
    isCurrentDocumentPath = function() return false end,
}, { __index = plugin })
local client = {
    server_url = "https://books.example", matchCheck = function() return {libraryVersion = 1, matches = {{hash = "hash", bookId = 1, bookFileId = 10}}} end,
    catalogBook = function(_, id) metadata_calls = metadata_calls + 1; return { id = id, genres = {"Manga"}, tags = {} } end,
}
local catalog = setmetatable({client = client, settings = {}}, {__index = Catalog})
local Routing = require("bookorbit_routing")
local before_install = Catalog.downloadFile
owner.bookorbit_download_rules = false
Routing.install(owner)
assert(Catalog.downloadFile == before_install, "off-by-default must not install hooks")
owner.bookorbit_download_rules = true
package.loaded.bookorbit_catalog = nil
Routing.install(owner)
assert(not Routing.installed and Catalog.downloadFile == before_install, "missing BookOrbit must not be auto-loaded")
package.loaded.bookorbit_catalog = Catalog
Routing.install(owner)
assert(Routing.status(owner))
local checks = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    assert(ok, name .. ": " .. tostring(err))
    checks = checks + 1
end
local function book(id, ext, title)
    return {id = id or 1, title = title or "Hirayasumi", authors = {"Keigo Shinzo"}, seriesName = "Hirayasumi", genres = {"Manga"}, tags = {"Slice of life"},
        files = {{id = (id or 1) * 10, format = ext or "epub", devicePath = "Server/Other/Volume 01." .. (ext or "epub"), fileHash = "hash", sizeBytes = 10}}, }
end
local expected = "/library/Manga/Hirayasumi/Shinzo, Keigo - Hirayasumi.epub"
local function openSheet(b)
    Dialog.last_page = nil
    local page = catalog:showDownloadOptions(b)
    return page or Dialog.last_page
end
local function flush() local queue = pending; pending = {}; for _, fn in ipairs(queue) do fn() end end
local function bulkctx()
    return { source = {}, index = 0, counts = {failed = 0, downloaded = 0, skipped_on_device = 0, skipped_existing = 0, skipped_unsupported = 0, path_conflicts = 0},
        failed_books = {}, failed_titles = {}, destination_paths = {}, path_conflicts = {}, completed = {}, page_completed = {}, existing_files = {}, resumed = false }
end

test("default download applies shared Swedish routing and filename; native root/link preserved", function()
    local b = book(); catalog:downloadDefaultFile(b, b.files[1]); flush()
    assert(transfers[#transfers], messages[#messages] or "no transfer")
    assert(transfers[#transfers].path == expected, transfers[#transfers].path)
    assert(transfers[#transfers].root == "/library")
    if native_dir then assert(links[#links] == expected) end
    if Dialog.last_page then Dialog.last_page:close() end
    assert(catalog:getCurrentDownloadDir() == "/native", "context leaked")
end)
test("sheet initially and repeatedly previews the actual destination, without rule or metadata reads", function()
    local b = book(); local page = openSheet(b)
    assert(page and page.preview[1] .. "/" .. page.preview[2] .. ".epub" == expected,
        page and table.concat(page.preview, "/") or messages[#messages])
    local count = metadata_calls
    for _ = 1, 12 do page:refresh() end
    assert(metadata_calls == count)
    page.on_action(page, {kind = "start"}); flush()
    assert(transfers[#transfers].path == expected)
    page:close()
end)
test("managed folder/name controls explain ownership and never save global download_dir", function()
    local page = openSheet(book())
    local count = #transfers
    page.on_action(page, {kind = "folder"}); page.on_action(page, {kind = "rename"})
    assert(saves == 0 and #transfers == count)
    assert(messages[#messages]:find("controlled by Library Sync", 1, true))
    page:close()
end)
test("setting change stops a stale sheet but cancel remains usable", function()
    local page = openSheet(book())
    owner.filename_profile = "calibre_title_authors"
    local count = #transfers
    page.on_action(page, {kind = "start"}); flush(); assert(#transfers == count)
    page.on_action(page, {kind = "cancel"}); assert(page.closed)
    owner.filename_profile = "sync_default"
end)
test("bulk fetches missing categories only when needed, then uses native transfer path", function()
    files[expected] = nil
    local b = book(); b.genres, b.tags = nil, nil
    local ctx = bulkctx(); local count = metadata_calls
    catalog:bulkProcessBook(ctx, b)
    assert(not ctx.library_sync_error, ctx.library_sync_error)
    assert(metadata_calls == count + 1)
    assert(transfers[#transfers].path == expected)
    assert(b.genres == nil and b.tags == nil, "native manifest mutated")
end)
test("flat/server-filename bulk needs no detail request", function()
    owner.routing_profile, owner.filename_profile = "flat", "grimmory_file"
    local b = book(2); b.genres, b.tags = nil, nil
    local count = metadata_calls
    catalog:bulkProcessBook(bulkctx(), b)
    assert(metadata_calls == count)
    assert(transfers[#transfers].path == "/library/Volume 01.epub")
    owner.routing_profile, owner.filename_profile = "swedish_genre_example", "sync_default"
end)
test("unavailable required metadata does not fall back or transfer", function()
    local b = book(); b.genres = nil
    local count = #transfers
    catalog:downloadDefaultFile(b, b.files[1]); flush(); assert(#transfers == count)
    assert(messages[#messages]:find("No fallback", 1, true))
end)
test("CBZ keeps its extension; local profile rules are shared", function()
    owner.routing_profile = "author"
    local b = book(3, "cbz"); catalog:downloadDefaultFile(b, b.files[1]); flush()
    assert(transfers[#transfers].path == "/library/Shinzo, Keigo/Shinzo, Keigo - Hirayasumi.cbz")
    owner.routing_profile = "swedish_genre_example"
end)
test("symlinks and replacement of open books are blocked", function()
    symlinks["/library/Manga"] = true
    local count = #transfers
    local b = book(); catalog:downloadDefaultFile(b, b.files[1]); flush(); assert(#transfers == count)
    symlinks["/library/Manga"] = nil
    owner.isCurrentDocumentPath = function() return true end
    catalog:downloadDefaultFile(b, b.files[1]); flush(); assert(#transfers == count)
    owner.isCurrentDocumentPath = function() return false end
end)
test("future BookOrbit version fails closed", function()
    version = "2.3.0"
    local count = #transfers; local b = book()
    catalog:downloadDefaultFile(b, b.files[1]); flush(); assert(#transfers == count)
    local ctx = bulkctx(); catalog:bulkProcessBook(ctx, b); assert(ctx.library_sync_error)
    local summary = catalog:bulkSummary(ctx)
    assert(type(summary) == "table" and summary.notes[#summary.notes]:find("Library Sync", 1, true)
        or type(summary) == "string" and summary:find("Library Sync", 1, true))
    version = base_version
end)
test("single direct callers cannot bypass the verified destination", function()
    local b = book(); local before = #transfers
    catalog:downloadFile("/elsewhere/book.epub", b, b.files[1]); flush()
    assert(#transfers == before)
end)
test("bulk reports unavailable categories without transferring or changing the source", function()
    local original = client.catalogBook
    client.catalogBook = function(_, id) return {id = id} end
    local b = book(80); b.genres, b.tags = nil, nil
    local before = #transfers; local ctx = bulkctx()
    catalog:bulkProcessBook(ctx, b)
    assert(#transfers == before and ctx.library_sync_error)
    assert(b.genres == nil and b.tags == nil)
    client.catalogBook = original
end)
test("bulk run cannot silently switch to native paths after disabling the integration", function()
    local b = book(81, "epub", "First bulk book")
    local ctx = bulkctx(); catalog:bulkProcessBook(ctx, b)
    assert(not ctx.library_sync_error, ctx.library_sync_error)
    owner.bookorbit_download_rules = false
    local before = #transfers
    catalog:bulkProcessBook(ctx, book(82, "epub", "Next bulk book"))
    assert(#transfers == before and ctx.cancel_requested and ctx.library_sync_error)
    owner.bookorbit_download_rules = true
end)
test("native bulk collision handling and skip-existing policies are retained", function()
    if not native_dir then return end
    local b = book(90, "epub", "Same title")
    local ctx = bulkctx(); catalog:bulkProcessBook(ctx, b)
    local first = transfers[#transfers].path
    catalog:bulkProcessBook(ctx, book(91, "epub", "Same title"))
    local second = transfers[#transfers].path
    assert(first ~= second and inside("/library", second) and second:match("%.epub$"))
    assert(ctx.counts.path_conflicts == 1)
    local before = #transfers
    catalog:bulkProcessBook(bulkctx(), b)
    assert(#transfers == before)
end)
test("native bulk skips already-linked books without fetching routing metadata", function()
    if not native_dir then return end
    local old = catalog.isOnDevice
    catalog.isOnDevice = function() return true end
    local b = book(92); b.genres, b.tags = nil, nil
    local before = metadata_calls; local ctx = bulkctx()
    catalog:bulkProcessBook(ctx, b)
    assert(metadata_calls == before and ctx.counts.skipped_on_device == 1)
    catalog.isOnDevice = old
end)
test("read-along edition refresh updates preview, final filename and native transfer", function()
    if not native_dir then return end
    owner.routing_profile, owner.filename_profile = "flat", "grimmory_file"
    local b = book(93)
    b.files[1].downloadVariant, b.files[1].sourceMediaOverlayAvailable = "original", true
    local selected = book(93)
    selected.files[1].downloadVariant = "audioless_epub"
    selected.files[1].devicePath = "Server/Volume 01 - text only.epub"
    local old = client.catalogBook
    client.catalogBook = function() return selected end
    local page = openSheet(b)
    page.on_action(page, {kind = "edition", index = 1})
    catalog.defer_connected = true
    page.on_action(page, {kind = "start"})
    local second = openSheet(book(95, "epub", "Another book"))
    flush()
    assert(transfers[#transfers].path == "/library/Volume 01 - text only.epub", messages[#messages])
    assert(page.result and page.result.path == transfers[#transfers].path)
    second:close()
    page:refresh() -- an older, still-open sheet retains its own route context
    page:close()
    local cancelled = openSheet(b)
    cancelled.on_action(cancelled, {kind = "edition", index = 1})
    local before = #transfers
    cancelled.on_action(cancelled, {kind = "start"})
    cancelled:close(); flush()
    assert(#transfers == before, "closed edition-selection dialog started a download")
    catalog.defer_connected = false
    client.catalogBook = old
    owner.routing_profile, owner.filename_profile = "swedish_genre_example", "sync_default"
end)
test("only-PDF sheet bypasses even invalid custom Library Sync rules", function()
    owner.routing_profile, owner.path_rules_file = "custom", "/missing-rules-file"
    local page = openSheet(book(94, "pdf"))
    assert(page and page.preview[1] == "/native/Server/Other")
    page:close()
    owner.routing_profile, owner.path_rules_file = "swedish_genre_example", nil
end)
test("disabled and other-server downloads are exactly native", function()
    local native_path = "/native/Server/Other/Volume 01.epub"
    local b = book()
    owner.bookorbit_download_rules = false
    catalog:downloadDefaultFile(b, b.files[1]); flush(); assert(transfers[#transfers].path == native_path)
    owner.bookorbit_download_rules = true
    client.server_url = "https://other.example"
    catalog:downloadDefaultFile(b, b.files[1]); flush(); assert(transfers[#transfers].path == native_path)
    client.server_url = "https://books.example"
end)
test("native PDF path unaffected even in a mixed-format download sheet", function()
    local b = book(); local pdf = {id = 11, format = "pdf", devicePath = "PDF/book.pdf", fileHash = "hash", sizeBytes = 10}
    b.files[#b.files + 1] = pdf
    local page = openSheet(b)
    page.on_action(page, {kind = "edition", index = 2})
    page:refresh(); assert(page.preview[1] == "/native/PDF")
    page:close()
    catalog:downloadDefaultFile(b, pdf); flush()
    assert(transfers[#transfers].path == "/native/PDF/book.pdf")
end)
test("missing server filename blocks only the managed request", function()
    owner.filename_profile = "grimmory_file"
    local b = book(); b.files[1].devicePath = nil
    local count = #transfers; catalog:downloadDefaultFile(b, b.files[1]); flush(); assert(#transfers == count)
    owner.filename_profile = "sync_default"
end)
test("Swedish labels and errors", function()
    language = "sv_SE"
    local menu = owner:getBookOrbitIntegrationMenu()
    assert(menu[1].text:find("Använd Library Syncs", 1, true))
    version = "9.0.0"
    local b = book(); catalog:downloadDefaultFile(b, b.files[1]); flush()
    assert(messages[#messages]:find("inte verifierad", 1, true))
    version, language = base_version, "en"
end)
test("setting is opt-in and persists without changing other saved settings", function()
    local original_open = io.open
    local saved, output = nil, {}
    io.open = function(path, mode)
        if path:match("/library_sync_settings%.txt$") then
            if mode == "w" then
                return {write = function(_, s) output[#output + 1] = s end, close = function() saved = table.concat(output) end}
            end
            if saved then return {lines = function() return saved:gmatch("([^\n]+)") end, close = function() end} end
        end
        return nil
    end
    owner.username, owner.password = "opds-user", "test-not-a-secret"
    assert(owner:loadSettings().bookorbit_download_rules == false)
    assert(owner:saveSettings())
    assert(saved:find("bookorbit_download_rules=true\n", 1, true))
    local loaded = owner:loadSettings()
    assert(loaded.bookorbit_download_rules and loaded.server_url == owner.server_url and loaded.local_path == owner.local_path)
    owner.bookorbit_download_rules = false; output = {}
    assert(owner:saveSettings()); assert(not owner:loadSettings().bookorbit_download_rules)
    owner.bookorbit_download_rules = true
    io.open = original_open
end)

test("custom rules share the engine, are read before the sheet, and fail closed", function()
    local native_dofile = dofile
    local rule_mode = "valid"
    dofile = function(path)
        if path ~= "/rules.lua" then return native_dofile(path) end
        rule_reads = rule_reads + 1
        if rule_mode == "load_error" then error("missing rules") end
        if rule_mode == "schema_error" then return {rules = "invalid"} end
        if rule_mode == "bad_template" then return {rules = {{path = 123}}} end
        return { rules = {{ when = function(b, h)
            if rule_mode == "callback_error" then error("bad custom rule") end
            return h.has_tag(b, "Slice of life")
        end, path = rule_mode == "escape" and "../Escape" or rule_mode == "reserved" and ".bookorbit-tmp" or "Tags/{series}" }}, fallback = "Other" }
    end
    files["/rules.lua"] = { mode = "file", size = 123, modification = 1 }
    owner.routing_profile, owner.path_rules_file = "custom", "/rules.lua"
    local page = openSheet(book())
    assert(page and page.preview[1] == "/library/Tags/Hirayasumi")
    local count = rule_reads
    for _ = 1, 20 do page:refresh() end
    assert(rule_reads == count)
    files["/rules.lua"].modification = 2
    local before = #transfers
    page.on_action(page, {kind = "start"}); flush(); assert(#transfers == before)
    page.on_action(page, {kind = "cancel"}); assert(page.closed)
    for _, mode in ipairs({"load_error", "callback_error", "escape", "reserved", "schema_error", "bad_template"}) do
        rule_mode = mode
        local b = book(); catalog:downloadDefaultFile(b, b.files[1]); flush(); assert(#transfers == before, mode)
    end
    owner.routing_profile, owner.path_rules_file = "swedish_genre_example", nil
    dofile = native_dofile
end)
test("replaced hooks are detected without removing another plugin's hook", function()
    local ours = Catalog.getLocalDownloadPath
    local foreign = function() return "/elsewhere" end
    Catalog.getLocalDownloadPath = foreign
    local count = #transfers; local b = book()
    catalog:downloadDefaultFile(b, b.files[1]); flush()
    assert(#transfers == count and Catalog.getLocalDownloadPath == foreign)
    Catalog.getLocalDownloadPath = ours
end)
assert(saves == 0)
print(string.format("BookOrbit routing: %d cases passed%s", checks, native_dir and " (real pinned BookOrbit download/bulk/sheet/path-check methods)" or ""))

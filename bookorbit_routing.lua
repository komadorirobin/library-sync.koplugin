-- Optional, fail-closed adapter for BookOrbit's native catalog downloads.
-- No BookOrbit files, global download_dir, file links or reading data are changed.
local M = {}
local unpack = unpack or table.unpack
local frames = setmetatable({}, { __mode = "k" })
local sheets = setmetatable({}, { __mode = "k" })
local hooks = {}
local MAIN_THREAD = {}
local SUPPORTED = { ["2.1.0"] = true, ["2.2.0"] = true }
local FORMATS = { epub = true, cbz = true }

function M.text(en, sv)
    local language = G_reader_settings and G_reader_settings:readSetting("language") or ""
    if tostring(language):match("^sv") then return sv end
    return require("gettext")(en)
end

local function pack(...) return { n = select("#", ...), ... } end
local function activeFrame(catalog)
    local running = frames[catalog]
    return running and running[coroutine.running() or MAIN_THREAD]
end
local function withFrame(catalog, frame, fn, ...)
    local running = frames[catalog]
    if not running then running = setmetatable({}, { __mode = "k" }); frames[catalog] = running end
    local thread = coroutine.running() or MAIN_THREAD
    local previous = running[thread]
    running[thread] = frame
    local result = pack(pcall(fn, ...))
    running[thread] = previous
    if not result[1] then error(result[2], 0) end
    return unpack(result, 2, result.n)
end

local function origin(url)
    if type(url) ~= "string" then return end
    url = url:match("^%s*(.-)%s*$"):gsub("/+$", "")
    url = url:gsub("/api/v1/opds.*$", ""):gsub("/api/v1$", "")
    local scheme, host, path = url:match("^(https?)://([^/]+)(.*)$")
    if not host or host:find("[@?#]") then return end
    -- Host/scheme are case-insensitive; a reverse proxy's path is not.
    return scheme:lower() .. "://" .. host:lower() .. path
end

local function wanted(catalog)
    local owner = M.owner
    if not owner or not owner.bookorbit_download_rules then return false end
    if owner.server_type ~= "bookorbit" then return false end
    local configured = origin(owner.server_url)
    local remote = catalog and catalog.client and origin(catalog.client.server_url)
    return configured ~= nil and configured == remote
end

local function pluginVersion()
    local ok, loader = pcall(require, "pluginloader")
    if ok and loader.getPluginInstance then
        local found, plugin = pcall(loader.getPluginInstance, loader, "bookorbit")
        if found and plugin then return plugin.PLUGIN_VERSION end
    end
end

local function available()
    if not SUPPORTED[pluginVersion()] then
        return nil, M.text("This BookOrbit plugin version has not been verified for Library Sync file rules.",
            "Den här versionen av BookOrbit-pluginet är inte verifierad för Library Syncs filregler.")
    end
    if not M.ready then
        return nil, M.text("BookOrbit's download interface is unavailable or has changed. Restart KOReader after updating both plugins.",
            "BookOrbits nedladdningsgränssnitt saknas eller har ändrats. Starta om KOReader efter att båda pluginen uppdaterats.")
    end
    for _, hook in ipairs(hooks) do
        if hook.object[hook.key] ~= hook.wrapper then
            return nil, M.text("Another plugin changed BookOrbit's download routing. Library Sync cannot safely apply its rules.",
                "Ett annat plugin har ändrat BookOrbits nedladdningsvägar. Library Sync kan inte tillämpa reglerna säkert.")
        end
    end
    return true
end

local function notify(message)
    require("logger").warn("[LibrarySync] BookOrbit download blocked:", message)
    require("ui/uimanager"):show(require("ui/widget/infomessage"):new{
        text = M.text("Library Sync: download stopped.\n\n", "Library Sync: nedladdningen stoppades.\n\n") .. tostring(message),
    })
end

local function managedMessage()
    return M.text("The folder and file name are controlled by Library Sync. Change its download folder/file rules, or turn this integration off.",
        "Mapp och filnamn styrs av Library Sync. Ändra dess mapp- och filnamnsregler, eller stäng av integrationen.")
end

local ERRORS_SV = {
    ["Invalid folder returned by Library Sync rules."] = "Library Syncs regler returnerade en ogiltig mapp.",
    ["Library Sync rules must return a relative folder."] = "Library Syncs regler måste returnera en relativ mapp.",
    ["Library Sync rules contain an unsafe folder component."] = "Library Syncs regler innehåller en osäker mappdel.",
    ["Set a valid Library Sync library folder first."] = "Ange först en giltig biblioteksmapp i Library Sync.",
    ["Library Sync's library folder is not canonical."] = "Library Syncs biblioteksmapp innehåller ogiltiga sökvägsdelar.",
    ["BookOrbit did not supply a book title."] = "BookOrbit skickade ingen boktitel.",
    ["BookOrbit did not supply the author required by the Library Sync rules."] = "BookOrbit skickade inte den författare som Library Syncs regler kräver.",
    ["Library Sync changed the selected file format."] = "Library Sync ändrade det valda filformatet.",
    ["Unsafe Library Sync download destination."] = "Osäker nedladdningssökväg i Library Sync.",
    ["No verified BookOrbit book context for Library Sync routing."] = "Ingen verifierad BookOrbit-bok finns för Library Syncs filregler.",
    ["Ambiguous BookOrbit download destination."] = "BookOrbits nedladdningssökväg är tvetydig.",
    ["The selected BookOrbit file was not part of the verified download plan."] = "Den valda BookOrbit-filen ingick inte i den verifierade nedladdningsplanen.",
    ["Close the open book before replacing its file."] = "Stäng den öppna boken innan dess fil ersätts.",
    ["Could not create the Library Sync destination folder."] = "Kunde inte skapa Library Syncs målmapp.",
    ["BookOrbit/Library Sync server settings changed. Reopen the download dialog."] = "Serverinställningarna i BookOrbit/Library Sync ändrades. Öppna nedladdningsrutan igen.",
    ["The download path no longer matches Library Sync's preview. Reopen the dialog."] = "Nedladdningssökvägen stämmer inte längre med Library Syncs förhandsvisning. Öppna rutan igen.",
    ["BookOrbit routing metadata could not be loaded."] = "Kunde inte hämta BookOrbit-metadata för filreglerna.",
    ["No verified Library Sync bulk destination."] = "Ingen verifierad Library Sync-sökväg finns för massnedladdningen.",
    ["Library Sync rules target a reserved working/trash folder."] = "Library Syncs regler pekar på en reserverad arbets- eller papperskorgsmapp.",
}
local function fail(message) error(ERRORS_SV[message] and M.text(message, ERRORS_SV[message]) or message, 0) end
local function checked()
    local ok, err = available()
    if not ok then fail(err) end
end

local function fingerprint(owner)
    return table.concat({ tostring(owner.server_type), tostring(owner.server_url), tostring(owner.local_path),
        tostring(owner.routing_profile), tostring(owner.path_rules_file), tostring(owner.filename_profile),
        tostring(owner.bookorbit_download_rules) }, "\0")
end

local function stamp(path)
    local attr = require("libs/libkoreader-lfs").attributes(path)
    return attr and table.concat({ tostring(attr.mode), tostring(attr.modification), tostring(attr.size) }, ":")
end

local function safeSubdir(value)
    if type(value) ~= "string" or value:find("[%z\1-\31]") then fail("Invalid folder returned by Library Sync rules.") end
    value = value:gsub("\\", "/")
    if value:match("^/") or value:match("^%a:") then fail("Library Sync rules must return a relative folder.") end
    for part in value:gmatch("[^/]+") do
        if part == "." or part == ".." then fail("Library Sync rules contain an unsafe folder component.") end
    end
    return value
end

local function policy()
    local owner = M.owner
    local root = tostring(owner.local_path or ""):gsub("/+$", "")
    if root == "" or root:sub(1, 1) ~= "/" or root:find("[%z\1-\31]") then fail("Set a valid Library Sync library folder first.") end
    for part in root:gmatch("[^/]+") do
        if part == "." or part == ".." then fail("Library Sync's library folder is not canonical.") end
    end
    local p = { root = root, fingerprint = fingerprint(owner), owner = owner }
    local worker = setmetatable({
        server_type = owner.server_type, filename_profile = owner.filename_profile,
        routing_profile = owner.routing_profile, path_rules_file = owner.path_rules_file,
    }, { __index = owner })
    if owner.routing_profile == "custom" then
        p.rules_stamp = stamp(owner.path_rules_file)
        local ok, rules = pcall(dofile, owner.path_rules_file or "")
        if not ok or (type(rules) ~= "table" and type(rules) ~= "function") then
            fail(M.text("Could not load the custom Library Sync rules. No fallback folder was used.",
                "Kunde inte läsa Library Syncs egna regler. Ingen reservmapp användes."))
        end
        if type(rules) == "table" then
            local valid = rules.resolve == nil or type(rules.resolve) == "function"
            if not rules.resolve then
                local list = rules.rules or rules
                valid = valid and type(list) == "table" and (rules.fallback == nil or type(rules.fallback) == "string")
                if valid then
                    for _, rule in ipairs(list) do
                        if type(rule) ~= "table" or (rule.when ~= nil and type(rule.when) ~= "function")
                            or (rule.path ~= nil and type(rule.path) ~= "string")
                            or (rule.folder ~= nil and type(rule.folder) ~= "string")
                            or (rule.fallback ~= nil and type(rule.fallback) ~= "string") then valid = false; break end
                    end
                end
            end
            if not valid then fail(M.text("The custom Library Sync rules have an invalid structure. No fallback folder was used.",
                "Library Syncs egna regler har ogiltig struktur. Ingen reservmapp användes.")) end
        end
        worker.customTargetPath = function(self, book)
            local helpers = self:pathRuleHelpers()
            local value
            if type(rules) == "function" then value = rules(book, helpers)
            elseif type(rules.resolve) == "function" then value = rules.resolve(book, helpers)
            else value = self:evaluateCustomRuleTable(rules, book, helpers, true) end
            return safeSubdir(value == nil and "" or value)
        end
    end
    worker.normalizeTargetSubdir = function(self, value)
        return owner.normalizeTargetSubdir(self, safeSubdir(value))
    end
    p.worker = worker
    p.needs_categories = owner:routingProfileRequiresGenres() or owner.routing_profile == "custom"
    return p
end

local function unchanged(p)
    if p.owner ~= M.owner or fingerprint(M.owner) ~= p.fingerprint
        or (p.worker.routing_profile == "custom" and stamp(M.owner.path_rules_file) ~= p.rules_stamp) then
        fail(M.text("Library Sync settings or rules changed. Close and reopen the download dialog/run.",
            "Library Syncs inställningar eller regler har ändrats. Stäng och öppna nedladdningen igen."))
    end
end

local function strings(values)
    local out = {}
    for _, value in ipairs(type(values) == "table" and values or {}) do
        if type(value) == "table" then value = value.name end
        if type(value) == "string" and value ~= "" then out[#out + 1] = value end
    end
    return out
end

local function format(file) return tostring(file and file.format or ""):lower() end
local function fileKey(file) return tostring(file.id) .. "\0" .. format(file) end
local function hasManagedFile(detail)
    for _, file in ipairs(detail.files or {}) do if FORMATS[format(file)] then return true end end
    return false
end

local function route(p, detail, file)
    if p.needs_categories and (type(detail.genres) ~= "table" or type(detail.tags) ~= "table") then
        fail(M.text("The folder rules need genres/tags, but BookOrbit did not supply them. No fallback folder was used.",
            "Mappreglerna behöver genrer/taggar, men BookOrbit skickade inte dessa. Ingen reservmapp användes."))
    end
    local ext = format(file)
    local source = file.fileName or file.filename or file.devicePath
    source = type(source) == "string" and source:gsub("\\", "/"):match("([^/]+)$") or nil
    if p.worker.filename_profile == "grimmory_file" and (not source or source == "") then
        fail(M.text("BookOrbit did not supply a server file name. Choose another naming profile in Library Sync.",
            "BookOrbit skickade inget serverfilnamn. Välj en annan filnamnsprofil i Library Sync."))
    end
    local book = {
        title = detail.title, author = table.concat(strings(detail.authors), ", "),
        series = detail.seriesName or detail.series, series_index = detail.seriesIndex,
        genres = strings(detail.genres), tags = strings(detail.tags), file_extension = ext,
        source_file_name = source, book_id = detail.id, book_file_id = file.id,
    }
    if type(book.title) ~= "string" or book.title == "" then fail("BookOrbit did not supply a book title.") end
    if (p.worker.routing_profile == "author" or p.worker.filename_profile == "sync_default") and book.author == "" then
        fail("BookOrbit did not supply the author required by the Library Sync rules.")
    end
    p.worker:mergeBookCategories(book, { genres = {}, tags = book.tags })
    local relative = p.worker:preferredDownloadRelativePath(book)
    safeSubdir(relative)
    for part in relative:gmatch("[^/]+") do
        if part == ".bookorbit-tmp" or part == ".library-sync-trash" then fail("Library Sync rules target a reserved working/trash folder.") end
    end
    local path = p.root .. "/" .. relative
    if path:sub(-#ext - 1):lower() ~= "." .. ext then fail("Library Sync changed the selected file format.") end
    if not require("bookorbit_download_transfer").isInsideRoot(p.root, path) then fail("Unsafe Library Sync download destination.") end
    return path
end

local function plan(catalog, detail, files, p)
    checked()
    p = p or policy()
    unchanged(p)
    local result = { policy = p, detail = detail, routes = {} }
    for _, file in ipairs(files or detail.files or {}) do
        if FORMATS[format(file)] then result.routes[fileKey(file)] = route(p, detail, file) end
    end
    return result
end

local function current(catalog)
    local frame = activeFrame(catalog)
    if frame then return frame end
    local page = sheets[catalog]
    if page and not page.closed then
        local edition = page.editions and page.editions[page.choice]
        if edition and not FORMATS[format(edition.file)] then return { bypass = true } end
        return page._library_sync_plan
    end
end

local function pathFor(catalog, filetype, device_path)
    local frame = current(catalog)
    if not frame then fail("No verified BookOrbit book context for Library Sync routing.") end
    local page = sheets[catalog]
    local detail = (page and not page.closed and page._library_sync_plan == frame and page.detail) or frame.detail
    local found
    for _, file in ipairs(detail.files or {}) do
        if format(file) == tostring(filetype):lower() and file.devicePath == device_path then
            local path = frame.routes[fileKey(file)]
            if path then
                if found and found ~= path then fail("Ambiguous BookOrbit download destination.") end
                found = path
            end
        end
    end
    if not found then fail("The selected BookOrbit file was not part of the verified download plan.") end
    return found, frame
end

local function prepare(catalog, path, p)
    unchanged(p)
    local transfer = require("bookorbit_download_transfer")
    if not transfer.isInsideRoot(p.root, path) then fail("Unsafe Library Sync download destination.") end
    if M.owner:isCurrentDocumentPath(path) then fail("Close the open book before replacing its file.") end
    if not M.owner:ensureDirectory(path:match("^(.+)/[^/]+$")) then fail("Could not create the Library Sync destination folder.") end
    if not transfer.isInsideRoot(p.root, path) then fail("Unsafe Library Sync download destination.") end
end

local function protect(fn, on_error, ...)
    local result = pack(pcall(fn, ...))
    if result[1] then return unpack(result, 2, result.n) end
    return on_error(result[2])
end

local function hook(object, key, build)
    local native = object[key]
    if type(native) ~= "function" then return false end
    local wrapper = build(native)
    object[key] = wrapper
    hooks[#hooks + 1] = { object = object, key = key, wrapper = wrapper }
    return true
end

local function blockBulk(catalog, ctx, book, err)
    catalog:bulkRecordFailure(ctx, book)
    catalog:bulkShowStatus(ctx, M.text("Library Sync file rules: download stopped", "Library Syncs filregler: nedladdningen stoppades"), book, true)
    require("logger").warn("[LibrarySync] BookOrbit bulk routing blocked:", tostring(err))
    -- Keep the reason in the run's normal failure report, not one popup per book.
    ctx.library_sync_error = tostring(err)
end

function M.install(owner)
    M.owner = owner
    if M.installed or not owner.bookorbit_download_rules then return end
    local Catalog = package.loaded["bookorbit_catalog"]
    if type(Catalog) ~= "table" then return end -- disabled/missing: never auto-load a plugin
    local ok, Dialog = pcall(require, "bookorbit_dialog_ui")
    if not ok or type(Dialog) ~= "table" then return end
    M.installed = true
    local required = { "getCurrentDownloadDir", "chooseDownloadDir", "getLocalDownloadPath", "getLocalDownloadPreview",
        "downloadDefaultFile", "downloadFile", "showDownloadOptions", "showDownloadDialog",
        "fetchDeliveryBook", "runConnected", "bulkResolveDestination", "bulkProcessBook", "bulkDownloadFile", "bulkSummary" }
    M.ready = type(Dialog.open) == "function"
    for _, name in ipairs(required) do if type(Catalog[name]) ~= "function" then M.ready = false end end

    hook(Catalog, "getCurrentDownloadDir", function(native) return function(catalog, ...)
        local frame = current(catalog)
        if wanted(catalog) and frame and not frame.bypass then return frame.policy.root end
        return native(catalog, ...)
    end end)
    hook(Catalog, "chooseDownloadDir", function(native) return function(catalog, ...)
        local frame = current(catalog)
        if wanted(catalog) and frame and not frame.bypass then return notify(managedMessage()) end
        return native(catalog, ...)
    end end)
    hook(Catalog, "getLocalDownloadPreview", function(native) return function(catalog, filename, ext, device_path, override)
        if not wanted(catalog) then return native(catalog, filename, ext, device_path, override) end
        if not FORMATS[tostring(ext):lower()] then
            return withFrame(catalog, { bypass = true }, native, catalog, filename, ext, device_path, override)
        end
        local path = pathFor(catalog, ext, device_path)
        local folder, name = path:match("^(.+)/([^/]+)$")
        return folder, name:sub(1, -#ext - 2)
    end end)
    hook(Catalog, "getLocalDownloadPath", function(native) return function(catalog, filename, ext, device_path, override)
        if not wanted(catalog) then return native(catalog, filename, ext, device_path, override) end
        if not FORMATS[tostring(ext):lower()] then
            return withFrame(catalog, { bypass = true }, native, catalog, filename, ext, device_path, override)
        end
        checked()
        local path, frame = pathFor(catalog, ext, device_path)
        prepare(catalog, path, frame.policy)
        return path
    end end)
    -- Choosing a different read-along edition returns a new file descriptor.
    -- Refresh the same plan before the sheet's callback computes its preview;
    -- never rerun rules from a paint callback or reuse the old edition's name.
    hook(Catalog, "fetchDeliveryBook", function(native) return function(catalog, ...)
        local result = pack(native(catalog, ...))
        local frame = current(catalog)
        if wanted(catalog) and frame and not frame.bypass and type(result[1]) == "table"
            and tostring(frame.detail.id) == tostring(result[1].id) then
            local ok, updated = pcall(plan, catalog, result[1], nil, frame.policy)
            if not ok then return nil, updated end
            frame.detail, frame.routes = updated.detail, updated.routes
        end
        return unpack(result, 1, result.n)
    end end)
    hook(Catalog, "runConnected", function(native) return function(catalog, callback, ...)
        local frame = activeFrame(catalog)
        if not wanted(catalog) or not frame or frame.bypass then return native(catalog, callback, ...) end
        return native(catalog, function(...)
            if frame.closed then return end
            return withFrame(catalog, frame, callback, ...)
        end, ...)
    end end)
    -- All initial sheet routes are calculated before painting. Subsequent builds
    -- read the immutable plan only: no custom-rule I/O or network from paint.
    hook(Dialog, "open", function(native) return function(opts, ...)
        if opts.name ~= "bookorbit_download_sheet" or not wanted(opts.catalog) then return native(opts, ...) end
        local frame = activeFrame(opts.catalog)
        if (frame and frame.bypass) or not hasManagedFile(opts.detail) then return native(opts, ...) end
        return protect(function()
            local scope = plan(opts.catalog, opts.detail)
            local definition = {}
            for key, value in pairs(opts) do definition[key] = value end
            local build = definition.build
            definition.build = function(page, ...)
                return withFrame(page.catalog, scope, build, page, ...)
            end
            local on_close = definition.on_close
            definition.on_close = function(page)
                scope.closed = true
                if sheets[page.catalog] == page then sheets[page.catalog] = nil end
                page._library_sync_plan = nil
                if on_close then return on_close(page) end
            end
            local action = definition.on_action
            definition.on_action = function(page, event)
                -- Dismiss/cancel and opening an already completed download must
                -- stay usable even after settings, credentials or rules change.
                if event.kind == "cancel" or event.kind == "close" or event.kind == "read" then return action(page, event) end
                local edition = page.editions and page.editions[page.choice]
                if edition and not FORMATS[format(edition.file)] then
                    return withFrame(page.catalog, { bypass = true }, action, page, event)
                end
                return protect(function()
                    checked(); unchanged(scope.policy)
                    if not wanted(page.catalog) then fail("BookOrbit/Library Sync server settings changed. Reopen the download dialog.") end
                    if event.kind == "rename" or event.kind == "folder" then return notify(managedMessage()) end
                    return withFrame(page.catalog, scope, action, page, event)
                end, notify)
            end
            local page = withFrame(opts.catalog, scope, native, definition)
            if page then page._library_sync_plan = scope; sheets[opts.catalog] = page end
            return page
        end, notify)
    end end)
    for _, name in ipairs({ "downloadDefaultFile", "showDownloadOptions", "showDownloadDialog" }) do
        local method = name
        hook(Catalog, name, function(native) return function(catalog, detail, ...)
            if not wanted(catalog) then return native(catalog, detail, ...) end
            local args = pack(...)
            if (method == "downloadDefaultFile" and not FORMATS[format(args[1])]) or not hasManagedFile(detail) then
                return withFrame(catalog, { bypass = true }, native, catalog, detail, unpack(args, 1, args.n))
            end
            return protect(function()
                local scope = plan(catalog, detail)
                return withFrame(catalog, scope, native, catalog, detail, unpack(args, 1, args.n))
            end, notify)
        end end)
    end
    hook(Catalog, "downloadFile", function(native) return function(catalog, path, detail, file, ui)
        if not wanted(catalog) or not FORMATS[format(file)] then return native(catalog, path, detail, file, ui) end
        return protect(function()
            local scope = plan(catalog, detail, { file })
            if scope.routes[fileKey(file)] ~= path then fail("The download path no longer matches Library Sync's preview. Reopen the dialog.") end
            prepare(catalog, path, scope.policy)
            return withFrame(catalog, scope, native, catalog, path, detail, file, ui)
        end, function(err)
            if ui and ui.finished then ui.finished(false, tostring(err)) end
            return notify(err)
        end)
    end end)
    hook(Catalog, "bulkProcessBook", function(native) return function(catalog, ctx, book)
        if ctx.library_sync_policy and not wanted(catalog) then
            ctx.cancel_requested = true
            return blockBulk(catalog, ctx, book, M.text("Server/settings changed. Start a new download run.", "Server/inställningar ändrades. Starta en ny nedladdning."))
        end
        if not wanted(catalog) then return native(catalog, ctx, book) end
        return protect(function()
            checked()
            if not (ctx.source and ctx.source.variant) and catalog:isOnDevice(book) then return native(catalog, ctx, book) end
            if book.files then
                local selected = catalog:bulkChooseFile(book, ctx.resumed)
                if not selected or not FORMATS[format(selected)] then
                    return withFrame(catalog, { bypass = true }, native, catalog, ctx, book)
                end
            end
            local p = ctx.library_sync_policy or policy()
            ctx.library_sync_policy = p
            unchanged(p)
            -- The native bulk manifest omits tags/genres. Fetch only this book,
            -- only when its routing profile needs them, inside the native worker.
            if book.files and p.needs_categories and (type(book.genres) ~= "table" or type(book.tags) ~= "table") then
                local detail = catalog.client:catalogBook(book.id, ctx.source and ctx.source.variant)
                if type(detail) ~= "table" or tostring(detail.id) ~= tostring(book.id) then fail("BookOrbit routing metadata could not be loaded.") end
                local enriched = {}
                for key, value in pairs(book) do enriched[key] = value end
                enriched.genres, enriched.tags = detail.genres, detail.tags
                book = enriched
            end
            return native(catalog, ctx, book)
        end, function(err) return blockBulk(catalog, ctx, book, err) end)
    end end)
    hook(Catalog, "bulkResolveDestination", function(native) return function(catalog, ctx, detail, file, id)
        if not wanted(catalog) or not FORMATS[format(file)] then return native(catalog, ctx, detail, file, id) end
        local scope = plan(catalog, detail, { file }, ctx.library_sync_policy)
        local path = withFrame(catalog, scope, native, catalog, ctx, detail, file, id)
        ctx.library_sync_destination = { path = path, scope = scope, key = fileKey(file), id = id }
        return path
    end end)
    hook(Catalog, "bulkDownloadFile", function(native) return function(catalog, ctx, detail, file, path, id)
        if not wanted(catalog) or not FORMATS[format(file)] then return native(catalog, ctx, detail, file, path, id) end
        local destination = ctx.library_sync_destination
        if not destination or destination.path ~= path or destination.key ~= fileKey(file) or destination.id ~= id then
            fail("No verified Library Sync bulk destination.")
        end
        prepare(catalog, path, destination.scope.policy)
        return withFrame(catalog, destination.scope, native, catalog, ctx, detail, file, path, id)
    end end)
    hook(Catalog, "bulkSummary", function(native) return function(catalog, ctx, ...)
        local summary = native(catalog, ctx, ...)
        if ctx.library_sync_error then
            local message = "Library Sync: " .. ctx.library_sync_error
            if type(summary) == "table" then
                summary.notes = summary.notes or {}
                summary.notes[#summary.notes + 1] = message
            else return tostring(summary) .. "\n\n" .. message end
        end
        return summary
    end end)
end

function M.status(owner)
    M.install(owner)
    return available()
end

return M

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local dump = require("dump")
local Updater = require("grimmory_updater")

local GrimmorySync = WidgetContainer:new{
    name = "grimmorysync",
    is_doc_only = false,
    abort_sync = false,
    abort_notified = false,
}

local SETTINGS_FILE = "/storage/emulated/0/koreader/grimmory_sync_settings.txt"
local LEGACY_SETTINGS_FILE = "/storage/emulated/0/koreader/booklore_sync_settings.txt"
local HISTORY_FILE = "/storage/emulated/0/koreader/grimmory_sync_history.lua"
local LEGACY_HISTORY_FILE = "/storage/emulated/0/koreader/booklore_sync_history.lua"
local MANIFEST_FILE = "/storage/emulated/0/koreader/grimmory_sync_manifest.lua"
local DEFAULT_LOCAL_PATH = "/storage/emulated/0/ePubs"
local DEFAULT_PATH_RULES_FILE = "/storage/emulated/0/koreader/grimmory_sync_path_rules.lua"
local MAX_HISTORY = 15
local PROGRESS_STEP_DELAY_S = 0.2
local AUTHOR_IMAGE_EXTS = { "jpg", "jpeg", "png", "gif", "bmp", "webp", "tiff", "tif" }
local SIGNATURE_SEPARATOR = "\31"
local ABORTED = "aborted"
local ROUTING_PROFILE_FLAT = "flat"
local ROUTING_PROFILE_AUTHOR = "author"
local ROUTING_PROFILE_GENRE_SERIES = "genre_series"
local ROUTING_PROFILE_CUSTOM = "custom"
local ROUTING_PROFILE_SWEDISH_EXAMPLE = "swedish_genre_example"
local LEGACY_ROUTING_PROFILE_SWEDISH_EXAMPLE = "robin_legacy"
local ROUTING_PROFILE_LIST = {
    { id = ROUTING_PROFILE_FLAT, label = _("Library root") },
    { id = ROUTING_PROFILE_AUTHOR, label = _("Author folders") },
    { id = ROUTING_PROFILE_GENRE_SERIES, label = _("Genre/series folders") },
    { id = ROUTING_PROFILE_CUSTOM, label = _("Custom rules file") },
    { id = ROUTING_PROFILE_SWEDISH_EXAMPLE, label = _("Swedish genre example") },
}

local function settingToBool(value, default)
    if value == nil or value == "" then
        return default
    end
    value = tostring(value):lower()
    return value == "true" or value == "1" or value == "yes" or value == "on"
end

local function boolToSetting(value)
    return value and "true" or "false"
end

local function isRoutingProfile(value)
    for _, profile in ipairs(ROUTING_PROFILE_LIST) do
        if profile.id == value then
            return true
        end
    end
    return false
end

local function trim(str)
    if type(str) ~= "string" then return "" end
    return str:gsub("^%s+", ""):gsub("%s+$", "")
end

local function jsonString(value)
    value = tostring(value or "")
    value = value:gsub("\\", "\\\\")
        :gsub('"', '\\"')
        :gsub("\n", "\\n")
        :gsub("\r", "\\r")
        :gsub("\t", "\\t")
    return '"' .. value .. '"'
end

local function jsonObject(values)
    local parts = {}
    for key, value in pairs(values) do
        parts[#parts + 1] = jsonString(key) .. ":" .. jsonString(value)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function urlEncode(value)
    return tostring(value or ""):gsub("([^%w%-_%.~])", function(char)
        return string.format("%%%02X", string.byte(char))
    end)
end

local function decodeJsonString(value)
    if not value then return nil end
    value = value:gsub("\\u(%x%x%x%x)", function(hex)
        local code = tonumber(hex, 16)
        if not code then return "" end
        if code < 0x80 then
            return string.char(code)
        elseif code < 0x800 then
            return string.char(
                0xC0 + math.floor(code / 0x40),
                0x80 + (code % 0x40)
            )
        end
        return string.char(
            0xE0 + math.floor(code / 0x1000),
            0x80 + (math.floor(code / 0x40) % 0x40),
            0x80 + (code % 0x40)
        )
    end)
    value = value:gsub("\\n", "\n")
        :gsub("\\r", "")
        :gsub("\\t", "\t")
        :gsub('\\"', '"')
        :gsub("\\/", "/")
        :gsub("\\\\", "\\")
    return value
end

local function jsonDecode(body)
    local ok_json, json = pcall(require, "json")
    if not ok_json or not json or type(json.decode) ~= "function" then
        return nil, _("Cannot load JSON parser")
    end

    local ok_decode, data = pcall(json.decode, body)
    if not ok_decode or type(data) ~= "table" then
        return nil, _("Could not parse JSON response")
    end
    return data, nil
end

local function jsonFieldString(object, field)
    local value = object:match('"' .. field .. '"%s*:%s*"(.-)"')
    return value and decodeJsonString(value) or nil
end

local function jsonFieldNumber(object, field)
    return object:match('"' .. field .. '"%s*:%s*(%-?%d+)')
end

local function jsonFieldBool(object, field)
    local value = object:match('"' .. field .. '"%s*:%s*(true)')
        or object:match('"' .. field .. '"%s*:%s*(false)')
    if value == "true" then return true end
    if value == "false" then return false end
    return nil
end

local function parseAuthorsFallback(body)
    local authors = {}
    if type(body) ~= "string" then return authors end

    for object in body:gmatch("{(.-)}") do
        local id = jsonFieldNumber(object, "id") or jsonFieldString(object, "id")
        local name = jsonFieldString(object, "name")
            or jsonFieldString(object, "authorName")
            or jsonFieldString(object, "fullName")
            or jsonFieldString(object, "displayName")

        if id and name and name ~= "" then
            authors[#authors + 1] = {
                id = id,
                name = name,
                hasPhoto = jsonFieldBool(object, "hasPhoto")
                    or jsonFieldBool(object, "has_photo")
                    or jsonFieldBool(object, "photo"),
                photoUrl = jsonFieldString(object, "photoUrl"),
                thumbnailUrl = jsonFieldString(object, "thumbnailUrl"),
                imageUrl = jsonFieldString(object, "imageUrl"),
            }
        end
    end

    return authors
end

local function parseBookMetadataFallback(body)
    local books = {}
    if type(body) ~= "string" then return books end

    local function findNextBookStart(start_pos)
        return body:find("{%s*\"id\"%s*:", start_pos)
    end

    local object_start = findNextBookStart(1)
    while object_start do
        local next_start = findNextBookStart(object_start + 1)
        local object = body:sub(object_start, (next_start or (#body + 1)) - 1)
        local id = jsonFieldNumber(object, "id") or jsonFieldString(object, "id")
        local hardcover_id = jsonFieldString(object, "hardcoverId")
        local hardcover_book_id = jsonFieldString(object, "hardcoverBookId")
            or jsonFieldNumber(object, "hardcoverBookId")

        if id and (hardcover_id or hardcover_book_id) then
            books[#books + 1] = {
                id = id,
                metadata = {
                    hardcoverId = hardcover_id,
                    hardcoverBookId = hardcover_book_id,
                },
            }
        end

        object_start = next_start
    end

    return books
end

function GrimmorySync:loadSettings()
    local file = io.open(SETTINGS_FILE, "r") or io.open(LEGACY_SETTINGS_FILE, "r")
    if not file then
        return {
            server_url = "",
            username = "",
            password = "",
            local_path = DEFAULT_LOCAL_PATH,
            sync_author_images = false,
            routing_profile = ROUTING_PROFILE_FLAT,
            path_rules_file = DEFAULT_PATH_RULES_FILE,
            selected_feed = "",
            selected_feed_label = "",
        }
    end
    
    local settings = {}
    for line in file:lines() do
        local key, value = line:match("^(.-)=(.*)$")
        if key then
            settings[key] = value
        end
    end
    file:close()

    local routing_profile = settings.routing_profile
    if routing_profile == nil or routing_profile == "" then
        routing_profile = ROUTING_PROFILE_SWEDISH_EXAMPLE
    elseif routing_profile == LEGACY_ROUTING_PROFILE_SWEDISH_EXAMPLE then
        routing_profile = ROUTING_PROFILE_SWEDISH_EXAMPLE
    elseif not isRoutingProfile(routing_profile) then
        routing_profile = ROUTING_PROFILE_FLAT
    end
    
    return {
        server_url = settings.server_url or "",
        username = settings.username or "",
        password = settings.password or "",
        local_path = settings.local_path or DEFAULT_LOCAL_PATH,
        sync_author_images = settingToBool(settings.sync_author_images, true),
        routing_profile = routing_profile,
        path_rules_file = settings.path_rules_file or DEFAULT_PATH_RULES_FILE,
        selected_feed = settings.selected_feed or "",
        selected_feed_label = settings.selected_feed_label or "",
    }
end

function GrimmorySync:saveSettings()
    local file = io.open(SETTINGS_FILE, "w")
    if not file then
        logger.warn("[GrimmorySync] Cannot save settings")
        return
    end
    
    file:write("server_url=" .. self.server_url .. "\n")
    file:write("username=" .. self.username .. "\n")
    file:write("password=" .. self.password .. "\n")
    file:write("local_path=" .. self.local_path .. "\n")
    file:write("sync_author_images=" .. boolToSetting(self.sync_author_images ~= false) .. "\n")
    file:write("routing_profile=" .. (self.routing_profile or ROUTING_PROFILE_FLAT) .. "\n")
    file:write("path_rules_file=" .. (self.path_rules_file or DEFAULT_PATH_RULES_FILE) .. "\n")
    file:write("selected_feed=" .. (self.selected_feed or "") .. "\n")
    file:write("selected_feed_label=" .. (self.selected_feed_label or "") .. "\n")
    file:close()
end

function GrimmorySync:loadHistory()
    local ok, history = pcall(dofile, HISTORY_FILE)
    if ok and type(history) == "table" then
        return history
    end

    ok, history = pcall(dofile, LEGACY_HISTORY_FILE)
    if ok and type(history) == "table" then
        return history
    end

    return {}
end

function GrimmorySync:saveHistory(history)
    local file = io.open(HISTORY_FILE, "w")
    if not file then
        logger.warn("[GrimmorySync] Cannot save history")
        return
    end
    file:write("return " .. dump(history) .. "\n")
    file:close()
end

function GrimmorySync:loadManifest()
    local ok, manifest = pcall(dofile, MANIFEST_FILE)
    if ok and type(manifest) == "table" then
        manifest.books = type(manifest.books) == "table" and manifest.books or {}
        return manifest
    end

    return {
        version = 1,
        books = {},
    }
end

function GrimmorySync:saveManifest(manifest)
    local file = io.open(MANIFEST_FILE, "w")
    if not file then
        logger.warn("[GrimmorySync] Cannot save manifest")
        return false
    end

    manifest.version = manifest.version or 1
    manifest.saved_at = os.time()
    manifest.books = type(manifest.books) == "table" and manifest.books or {}

    file:write("return " .. dump(manifest) .. "\n")
    file:close()
    return true
end

function GrimmorySync:recordDownload(book, file_path)
    local history = self:loadHistory()
    table.insert(history, 1, {
        timestamp = os.time(),
        title = book.title or _("Unknown title"),
        author = book.author or "",
        path = file_path,
    })
    -- Keep only the most recent entries
    while #history > MAX_HISTORY do
        table.remove(history)
    end
    self:saveHistory(history)
end

function GrimmorySync:getRecentBooksMenu()
    local history = self:loadHistory()

    if #history == 0 then
        return {
            {
                text = _("No downloads yet"),
                enabled = false,
            },
        }
    end

    local items = {}
    for _, entry in ipairs(history) do
        local date_str = os.date("%Y-%m-%d", entry.timestamp)
        local display = entry.title
        if entry.author and entry.author ~= "" then
            display = entry.author .. " – " .. display
        end
        display = display .. "  [" .. date_str .. "]"

        local entry_ref = entry
        table.insert(items, {
            text = display,
            callback = function(touchmenu_instance)
                self:runAfterMenuClose(touchmenu_instance, function()
                    self:openRecentBook(entry_ref)
                end)
            end,
        })
    end

    table.insert(items, {
        text = "———",
        enabled = false,
    })
    table.insert(items, {
        text = _("Clear history"),
        callback = function(touchmenu_instance)
            self:runAfterMenuClose(touchmenu_instance, function()
                UIManager:show(ConfirmBox:new{
                    text = _("Clear the entire download history?"),
                    ok_text = _("Clear"),
                    cancel_text = _("Cancel"),
                    ok_callback = function()
                        self:saveHistory({})
                        UIManager:show(InfoMessage:new{
                            text = _("History cleared."),
                            timeout = 2,
                        })
                    end,
                })
            end)
        end,
    })

    return items
end

function GrimmorySync:openRecentBook(entry)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then
        UIManager:show(InfoMessage:new{
            text = _("Could not check the file."),
            timeout = 3,
        })
        return
    end

    local ok_attr, attr = pcall(lfs.attributes, entry.path)
    if ok_attr and attr and attr.mode == "file" then
        local ReaderUI = require("apps/reader/readerui")
        ReaderUI:showReader(entry.path)
    else
        UIManager:show(InfoMessage:new{
            text = string.format(_("File not found:\n%s"), entry.path or _("unknown path")),
            timeout = 3,
        })
    end
end

function GrimmorySync:runAfterMenuClose(touchmenu_instance, callback)
    if type(touchmenu_instance) == "function" and callback == nil then
        callback = touchmenu_instance
        touchmenu_instance = nil
    end
    if touchmenu_instance then
        UIManager:close(touchmenu_instance)
    end
    -- Menu callbacks can still be on screen while they are executing.
    -- Deferring by one UI turn avoids stacking dialogs behind/over the menu.
    UIManager:scheduleIn(0.1, callback)
end

function GrimmorySync:init()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    
    local settings = self:loadSettings()
    self.server_url = settings.server_url
    self.username = settings.username
    self.password = settings.password
    self.local_path = settings.local_path
    self.sync_author_images = settings.sync_author_images ~= false
    self.routing_profile = settings.routing_profile
    self.path_rules_file = settings.path_rules_file
    self.selected_feed = settings.selected_feed or ""
    self.selected_feed_label = settings.selected_feed_label or ""
end

function GrimmorySync:addToMainMenu(menu_items)
    menu_items.grimmory_sync = {
        text = _("Grimmory Sync"),
        sorting_hint = "search",
        sub_item_table = {
            {
                text = _("Sync missing books"),
                callback = function(touchmenu_instance)
                    self:runAfterMenuClose(touchmenu_instance, function()
                        self:startSync()
                    end)
                end,
            },
            {
                text = _("Refresh existing metadata"),
                callback = function(touchmenu_instance)
                    self:runAfterMenuClose(touchmenu_instance, function()
                        self:startMetadataRefresh()
                    end)
                end,
            },
            {
                text = _("Bookshelf integration"),
                sub_item_table_func = function()
                    return self:getBookshelfIntegrationMenu()
                end,
            },
            {
                text = _("Download folder profile"),
                sub_item_table_func = function()
                    return self:getRoutingProfileMenu()
                end,
            },
            {
                text = _("Check for updates"),
                callback = function(touchmenu_instance)
                    self:runAfterMenuClose(touchmenu_instance, function()
                        Updater.checkForUpdates()
                    end)
                end,
            },
            {
                text = _("Recent books"),
                sub_item_table_func = function()
                    return self:getRecentBooksMenu()
                end,
            },
            {
                text = _("Configure"),
                callback = function(touchmenu_instance)
                    self:runAfterMenuClose(touchmenu_instance, function()
                        self:showServerConfig()
                    end)
                end,
            },
            {
                text = _("Select shelf to sync"),
                sub_item_table_func = function()
                    return self:getShelfSelectionMenu()
                end,
            },
            {
                text = _("Show status"),
                callback = function(touchmenu_instance)
                    self:runAfterMenuClose(touchmenu_instance, function()
                        self:showStatus()
                    end)
                end,
            },
        },
    }
end

function GrimmorySync:getBookshelfIntegrationMenu()
    return {
        {
            text = _("Sync Bookshelf author images during metadata refresh"),
            checked_func = function()
                return self.sync_author_images ~= false
            end,
            keep_menu_open = true,
            callback = function()
                self.sync_author_images = not (self.sync_author_images ~= false)
                self:saveSettings()
                UIManager:show(InfoMessage:new{
                    text = self.sync_author_images
                        and _("Bookshelf author image sync enabled")
                        or _("Bookshelf author image sync disabled"),
                    timeout = 2,
                })
            end,
        },
        {
            text = _("Show Bookshelf author image path"),
            callback = function(touchmenu_instance)
                self:runAfterMenuClose(touchmenu_instance, function()
                    UIManager:show(InfoMessage:new{
                        text = string.format(_("Bookshelf author images are written to:\n%s"), self:authorImagesPath()),
                        timeout = 6,
                    })
                end)
            end,
        },
    }
end

function GrimmorySync:routingProfileLabel(profile_id)
    for _, profile in ipairs(ROUTING_PROFILE_LIST) do
        if profile.id == profile_id then
            return profile.label
        end
    end
    return ROUTING_PROFILE_LIST[1].label
end

function GrimmorySync:getRoutingProfileMenu()
    local items = {}
    for _, profile in ipairs(ROUTING_PROFILE_LIST) do
        local profile_id = profile.id
        local profile_label = profile.label
        table.insert(items, {
            text = profile_label,
            checked_func = function()
                return (self.routing_profile or ROUTING_PROFILE_FLAT) == profile_id
            end,
            keep_menu_open = true,
            callback = function()
                self.routing_profile = profile_id
                self:saveSettings()
                UIManager:show(InfoMessage:new{
                    text = string.format(_("Download folder profile: %s"), profile_label),
                    timeout = 2,
                })
            end,
        })
    end

    table.insert(items, {
        text = "———",
        enabled = false,
    })
    table.insert(items, {
        text = _("Custom rules file path"),
        callback = function(touchmenu_instance)
            self:runAfterMenuClose(touchmenu_instance, function()
                self:showPathRulesFileConfig()
            end)
        end,
    })

    return items
end

function GrimmorySync:showServerConfig()
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Grimmory Server URL"),
        input = self.server_url,
        input_hint = "http://192.168.1.100:6060",
        input_type = "text",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("Next"),
                    callback = function()
                        self.server_url = input_dialog:getInputText()
                        UIManager:close(input_dialog)
                        self:showUsernameConfig()
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function GrimmorySync:showUsernameConfig()
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Username (optional)"),
        input = self.username,
        input_type = "text",
        buttons = {
            {
                {
                    text = _("Back"),
                    callback = function()
                        UIManager:close(input_dialog)
                        self:showServerConfig()
                    end,
                },
                {
                    text = _("Next"),
                    callback = function()
                        self.username = input_dialog:getInputText()
                        UIManager:close(input_dialog)
                        self:showPasswordConfig()
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function GrimmorySync:showPasswordConfig()
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Password (optional)"),
        input = self.password,
        input_type = "text",
        text_type = "password",
        buttons = {
            {
                {
                    text = _("Back"),
                    callback = function()
                        UIManager:close(input_dialog)
                        self:showUsernameConfig()
                    end,
                },
                {
                    text = _("Next"),
                    callback = function()
                        self.password = input_dialog:getInputText()
                        UIManager:close(input_dialog)
                        self:showPathConfig()
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function GrimmorySync:showPathConfig()
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Local book path"),
        input = self.local_path,
        input_hint = DEFAULT_LOCAL_PATH,
        input_type = "text",
        buttons = {
            {
                {
                    text = _("Back"),
                    callback = function()
                        UIManager:close(input_dialog)
                        self:showPasswordConfig()
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        self.local_path = input_dialog:getInputText()
                        self:saveSettings()
                        UIManager:close(input_dialog)
                        
                        UIManager:show(InfoMessage:new{
                            text = _("Configuration saved."),
                            timeout = 2,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function GrimmorySync:showPathRulesFileConfig()
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Custom rules file path"),
        input = self.path_rules_file or DEFAULT_PATH_RULES_FILE,
        input_hint = DEFAULT_PATH_RULES_FILE,
        input_type = "text",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        self.path_rules_file = input_dialog:getInputText()
                        if self.path_rules_file == "" then
                            self.path_rules_file = DEFAULT_PATH_RULES_FILE
                        end
                        self:saveSettings()
                        UIManager:close(input_dialog)

                        UIManager:show(InfoMessage:new{
                            text = _("Custom rules path saved."),
                            timeout = 2,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function GrimmorySync:scanLocalBooks()
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then
        logger.err("[GrimmorySync] Cannot load lfs")
        return {}
    end
    
    local books = {}
    local function scanDirectory(path, relative_path)
        local ok_dir, iter, dir_obj = pcall(lfs.dir, path)
        if not ok_dir then return end
        
        for entry in iter, dir_obj do
            if entry ~= "." and entry ~= ".." then
                local full_path = path .. "/" .. entry
                local rel_path = relative_path and (relative_path .. "/" .. entry) or entry
                local ok_attr, attr = pcall(lfs.attributes, full_path)
                
                if ok_attr and attr then
                    if attr.mode == "directory" then
                        scanDirectory(full_path, rel_path)
                    elseif attr.mode == "file" then
                        local ext = full_path:match("%.([^%.]+)$")
                        if ext and (ext:lower() == "epub" or ext:lower() == "pdf" or 
                                   ext:lower() == "mobi" or ext:lower() == "azw3") then
                            -- Store the relative path from local_path, including subdirs and extension
                            table.insert(books, {
                                path = full_path,
                                filename = rel_path,  -- Keep extension for matching
                            })
                        end
                    end
                end
            end
        end
    end
    
    local ok_attr, attr = pcall(lfs.attributes, self.local_path)
    if ok_attr and attr and attr.mode == "directory" then
        scanDirectory(self.local_path, nil)
    end
    
    logger.info("[GrimmorySync] Found", #books, "local books")
    return books
end

function GrimmorySync:buildServerUrl(endpoint)
    if type(endpoint) == "string" and endpoint:match("^https?://") then
        return endpoint
    end

    local base = trim(self.server_url):gsub("/+$", "")
    endpoint = tostring(endpoint or "")
    if endpoint:sub(1, 1) ~= "/" then
        endpoint = "/" .. endpoint
    end
    return base .. endpoint
end

function GrimmorySync:ensureDirectory(path)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then
        logger.err("[GrimmorySync] Cannot load lfs")
        return false
    end

    if type(path) ~= "string" or path == "" then
        return false
    end

    local is_absolute = path:match("^/")
    local current = is_absolute and "" or nil
    for part in path:gmatch("[^/]+") do
        if current == nil then
            current = part
        elseif current == "" then
            current = "/" .. part
        else
            current = current .. "/" .. part
        end

        local attr = lfs.attributes(current)
        if not attr then
            local ok, err = lfs.mkdir(current)
            if not ok then
                logger.err("[GrimmorySync] Cannot create directory:", current, "error:", err or "unknown")
                return false
            end
            logger.info("[GrimmorySync] Created directory:", current)
        elseif attr.mode ~= "directory" then
            logger.err("[GrimmorySync] Path is not a directory:", current)
            return false
        end
    end

    return true
end

function GrimmorySync:httpRequest(url, options)
    options = options or {}

    local ok_http, http = pcall(require, "socket.http")
    local ok_https, https = pcall(require, "ssl.https")
    local ok_ltn12, ltn12 = pcall(require, "ltn12")

    if not ok_http or not ok_ltn12 then
        return nil, _("Cannot load HTTP libraries")
    end

    local headers = {}
    for key, value in pairs(options.headers or {}) do
        headers[key] = value
    end

    local request = {
        url = url,
        method = options.method or "GET",
        headers = headers,
        sink = options.sink,
    }

    local response_body
    if not request.sink then
        response_body = {}
        request.sink = ltn12.sink.table(response_body)
    end

    if options.body then
        headers["content-length"] = tostring(#options.body)
        request.source = ltn12.source.string(options.body)
    end

    local request_func = url:match("^https://")
        and (ok_https and https.request or http.request)
        or http.request

    local success, status_code, response_headers = request_func(request)
    local status_num = tonumber(status_code)
    local body = response_body and table.concat(response_body) or true

    if not success then
        return body, string.format(_("Connection failed: %s"), tostring(status_code)), status_code, response_headers
    end

    if status_num and (status_num < 200 or status_num >= 300) then
        return body, string.format(_("HTTP %s"), tostring(status_code)), status_code, response_headers
    end

    return body, nil, status_code, response_headers
end

function GrimmorySync:makeRequest(endpoint)
    local headers = {}
    if self.username ~= "" and self.password ~= "" then
        local mime = require("mime")
        headers["authorization"] = "Basic " .. mime.b64(self.username .. ":" .. self.password)
    end

    local body, err = self:httpRequest(self:buildServerUrl(endpoint), {
        headers = headers,
    })
    if err then
        return nil, err
    end

    return body, nil
end

function GrimmorySync:fetchShelves()
    -- Fetch the navigation feeds that contain acquisition sub-feeds we can sync.
    -- Aggregates personal shelves and magic (dynamic) shelves into one list.
    local sources = {
        { endpoint = "/api/v1/opds/shelves", prefix = "" },
        { endpoint = "/api/v1/opds/magic-shelves", prefix = "[Magic] " },
    }
    local shelves = {}
    local any_ok = false
    local last_err
    for _, source in ipairs(sources) do
        local response, err = self:makeRequest(source.endpoint)
        if response then
            any_ok = true
            for entry in response:gmatch("<entry>(.-)</entry>") do
                local title = entry:match("<title>(.-)</title>")
                local href
                for link in entry:gmatch('<link([^>]*)') do
                    local rel = link:match('rel="([^"]+)"')
                    local type_attr = link:match('type="([^"]+)"')
                    -- Only follow links that lead to an acquisition feed (actual books)
                    if href == nil and (
                        (type_attr and type_attr:match("acquisition"))
                        or (rel and rel:match("subsection"))
                    ) then
                        local candidate = link:match('href="([^"]+)"') or link:match("href='([^']+)'")
                        if candidate then
                            href = candidate:gsub("&amp;", "&")
                            -- Prefer acquisition feeds; keep looking if this was only a navigation subsection
                            if type_attr and type_attr:match("acquisition") then
                                break
                            end
                        end
                    end
                end
                if title then
                    title = title:gsub("&amp;", "&")
                        :gsub("&apos;", "'")
                        :gsub("&#39;", "'")
                        :gsub("&quot;", '"')
                        :gsub("&lt;", "<")
                        :gsub("&gt;", ">")
                end
                if title and href then
                    shelves[#shelves + 1] = { label = source.prefix .. title, href = href }
                end
            end
        else
            last_err = err
        end
    end
    if not any_ok then
        return nil, last_err or _("Could not load shelves")
    end
    return shelves, nil
end

function GrimmorySync:getShelfSelectionMenu()
    local items = {
        {
            text = _("All books (default)"),
            checked_func = function()
                return (self.selected_feed or "") == ""
            end,
            keep_menu_open = true,
            callback = function()
                self.selected_feed = ""
                self.selected_feed_label = ""
                self:saveSettings()
            end,
        },
        { text = "———", enabled = false },
    }

    local shelves, err = self:fetchShelves()
    if not shelves then
        items[#items + 1] = {
            text = string.format(_("Could not load shelves: %s"), tostring(err)),
            enabled = false,
        }
        return items
    end

    if #shelves == 0 then
        items[#items + 1] = {
            text = _("No shelves found on server"),
            enabled = false,
        }
        return items
    end

    for _, shelf in ipairs(shelves) do
        local href = shelf.href
        local label = shelf.label
        items[#items + 1] = {
            text = label,
            checked_func = function()
                return self.selected_feed == href
            end,
            keep_menu_open = true,
            callback = function()
                self.selected_feed = href
                self.selected_feed_label = label
                self:saveSettings()
            end,
        }
    end

    return items
end

function GrimmorySync:fetchBooklistFromGrimmory()
    logger.info("[GrimmorySync] Fetching books from:", self.server_url)
    logger.info("[GrimmorySync] Username:", self.username)
    
    -- First, get the root OPDS catalog to find the "All Books" link
    local root_response, err = self:makeRequest("/api/v1/opds")
    
    -- If 401, try without authentication
    if err and err:match("401") then
        logger.info("[GrimmorySync] Got 401, trying without auth...")
        local old_user, old_pass = self.username, self.password
        self.username, self.password = "", ""
        root_response, err = self:makeRequest("/api/v1/opds")
        self.username, self.password = old_user, old_pass
        
        if err then
            return nil, _("OPDS endpoint requires authentication but credentials were rejected (401). Please verify username and password.")
        end
    end
    
    if not root_response then
        return nil, err
    end
    
    -- Determine which acquisition feed to follow.
    -- If the user selected a specific shelf, use its feed directly; otherwise
    -- fall back to discovering the "All Books"/"Catalog" link from the root feed.
    local catalog_link
    if self.selected_feed and self.selected_feed ~= "" then
        catalog_link = self.selected_feed
        logger.info("[GrimmorySync] Using selected feed:",
            self.selected_feed_label or "(unnamed)", catalog_link)
    else
        for entry in root_response:gmatch("<entry>(.-)</entry>") do
            local title = entry:match("<title>(.-)</title>")
            if title and (title:match("All Books") or title:match("Catalog")) then
                for link in entry:gmatch('<link([^>]*)') do
                    catalog_link = link:match('href="([^"]+)"') or link:match("href='([^']+)'")
                    if catalog_link then
                        -- Decode HTML entities
                        catalog_link = catalog_link:gsub("&amp;", "&")
                        break
                    end
                end
            end
            if catalog_link then break end
        end
    end

    if not catalog_link then
        return nil, _("Could not find 'All Books' catalog link in OPDS feed")
    end
    
    logger.info("[GrimmorySync] Following catalog link:", catalog_link)
    
    -- Fetch all pages with pagination support
    local books = {}
    local current_link = catalog_link
    local page_count = 0
    local max_pages = 100  -- Safety limit to prevent infinite loops
    
    while current_link and page_count < max_pages do
        page_count = page_count + 1
        logger.info("[GrimmorySync] Fetching page", page_count, ":", current_link)
        
        local response, err = self:makeRequest(current_link)
        if not response then
            if page_count == 1 then
                return nil, err  -- Fail if first page fails
            else
                logger.warn("[GrimmorySync] Failed to fetch page", page_count, ":", err)
                break  -- Stop pagination but return what we have
            end
        end
        
        -- Parse books from this page
        for entry in response:gmatch("<entry>(.-)</entry>") do
            local title = entry:match("<title>(.-)</title>")
            local author = entry:match("<author>.-<name>(.-)</name>.-</author>")
            -- Try alternative author formats if first pattern doesn't match
            if not author then
                author = entry:match("<author>(.-)</author>")
            end
            if not author then
                author = entry:match('<dc:creator>(.-)</dc:creator>')
            end
            -- Remove XML tags if author still contains them
            if author then
                author = author:gsub("<[^>]+>", "")
                author = author:gsub("^%s+", ""):gsub("%s+$", "")
                if author == "" then author = nil end
            end
            
            -- Decode HTML entities in title and author
            -- &amp; must be decoded FIRST to handle double-encoded entities (e.g. &amp;apos; -> &apos; -> ')
            if title then
                title = title:gsub("&amp;", "&")
                title = title:gsub("&apos;", "'")
                title = title:gsub("&#39;", "'")
                title = title:gsub("&quot;", '"')
                title = title:gsub("&lt;", "<")
                title = title:gsub("&gt;", ">")
            end
            if author then
                author = author:gsub("&amp;", "&")
                author = author:gsub("&apos;", "'")
                author = author:gsub("&#39;", "'")
                author = author:gsub("&quot;", '"')
                author = author:gsub("&lt;", "<")
                author = author:gsub("&gt;", ">")
            end

            local description = entry:match("<summary[^>]*>(.-)</summary>")
                or entry:match("<content[^>]*>(.-)</content>")
            if description then
                description = description:gsub("<!%[CDATA%[(.-)%]%]>", "%1")
                description = description:gsub("<[^>]+>", "")
                description = description:gsub("&amp;", "&")
                description = description:gsub("&apos;", "'")
                description = description:gsub("&#39;", "'")
                description = description:gsub("&quot;", '"')
                description = description:gsub("&lt;", "<")
                description = description:gsub("&gt;", ">")
                description = description:gsub("%s+", " ")
                description = description:gsub("^%s+", ""):gsub("%s+$", "")
                if description == "" then description = nil end
            end

            local download_link
            
            -- Extract genres/tags (category elements)
            local genres = {}
            for category in entry:gmatch('<category[^>]*term="([^"]+)"') do
                table.insert(genres, category)
            end
            
            -- Extract series and series index
            -- First try OPDS standard (belongs-to-collection)
            local series = entry:match('<meta[^>]*property="belongs%-to%-collection"[^>]*id="series"[^>]*>([^<]+)</meta>')
            local series_index = entry:match('<meta[^>]*property="group%-position"[^>]*refines="#series"[^>]*>([^<]+)</meta>')
            
            -- Fallback to Calibre compatibility format
            if not series then
                series = entry:match('<meta[^>]*name="calibre:series"[^>]*content="([^"]+)"')
            end
            if not series_index then
                series_index = entry:match('<meta[^>]*name="calibre:series_index"[^>]*content="([^"]+)"')
            end
            
            -- Decode HTML entities in series name
            -- &amp; must be decoded FIRST to handle double-encoded entities (e.g. &amp;apos; -> &apos; -> ')
            if series then
                series = series:gsub("&amp;", "&")
                series = series:gsub("&apos;", "'")
                series = series:gsub("&#39;", "'")
                series = series:gsub("&quot;", '"')
                series = series:gsub("&lt;", "<")
                series = series:gsub("&gt;", ">")
            end
            
            -- Extract updated/published timestamp. Grimmory metadata rewrites
            -- should change one of these; the full value is kept for refresh
            -- decisions while the year is still used for folder naming.
            local updated = entry:match("<updated>(.-)</updated>")
            local published = entry:match("<published>(.-)</published>")
            local metadata_timestamp = updated or published
            local year
            if metadata_timestamp then
                year = metadata_timestamp:match("(%d%d%d%d)")
            end
            
            -- Look for acquisition links (actual book downloads)
            for link in entry:gmatch('<link([^>]*)>') do
                local rel = link:match('rel="([^"]+)"')
                local type_attr = link:match('type="([^"]+)"')
                
                -- Check for acquisition link with epub type
                if rel and rel:match("acquisition") and type_attr and type_attr:match("epub") then
                    download_link = link:match('href="([^"]+)"') or link:match("href='([^']+)'")
                    if download_link then
                        download_link = download_link:gsub("&amp;", "&")
                        break
                    end
                end
            end
            
            -- Also try self-closing links
            if not download_link then
                for link in entry:gmatch('<link([^>]*)/[>]?') do
                    local rel = link:match('rel="([^"]+)"')
                    local type_attr = link:match('type="([^"]+)"')
                    
                    if rel and rel:match("acquisition") and type_attr and type_attr:match("epub") then
                        download_link = link:match('href="([^"]+)"') or link:match("href='([^']+)'")
                        if download_link then
                            download_link = download_link:gsub("&amp;", "&")
                            break
                        end
                    end
                end
            end
            
            if title and download_link then
                local book_id = entry:match("<id>urn:booklore:book:(%d+)</id>")
                    or download_link:match("/opds/(%d+)/download")
                    or download_link:match("[?&]fileId=(%d+)")
                logger.info("[GrimmorySync] Found book:", title, "by", author or "Unknown", "series:", series or "none", "->", download_link)
                table.insert(books, {
                    book_id = book_id,
                    title = title,
                    author = author,
                    series = series,
                    series_index = series_index,
                    year = year,
                    updated = updated,
                    published = published,
                    description = description,
                    genres = genres,
                    download_url = download_link,
                })
            elseif title then
                logger.warn("[GrimmorySync] Book without download link:", title)
            end
        end
        
        -- Look for "next" link for pagination
        local next_link = nil
        for link in response:gmatch('<link([^>]*)>') do
            local rel = link:match('rel="([^"]+)"')
            if rel and rel == "next" then
                next_link = link:match('href="([^"]+)"') or link:match("href='([^']+)'")
                if next_link then
                    next_link = next_link:gsub("&amp;", "&")
                    break
                end
            end
        end
        
        -- Also try self-closing next links
        if not next_link then
            for link in response:gmatch('<link([^>]*)/[>]?') do
                local rel = link:match('rel="([^"]+)"')
                if rel and rel == "next" then
                    next_link = link:match('href="([^"]+)"') or link:match("href='([^']+)'")
                    if next_link then
                        next_link = next_link:gsub("&amp;", "&")
                        break
                    end
                end
            end
        end
        
        if next_link then
            logger.info("[GrimmorySync] Found next page link:", next_link)
            current_link = next_link
        else
            logger.info("[GrimmorySync] No more pages, stopping at page", page_count)
            break
        end
    end
    
    if page_count >= max_pages then
        logger.warn("[GrimmorySync] Reached maximum page limit (", max_pages, "), there may be more books")
    end
    
    logger.info("[GrimmorySync] Found", #books, "remote books across", page_count, "pages")
    return books, nil
end

function GrimmorySync:convertAuthorName(author)
    if not author or author == "" then
        return "Unknown"
    end
    
    -- Check if already in "Last, First" format
    if author:match(",") then
        return author
    end
    
    -- Split name into words
    local words = {}
    for word in author:gmatch("%S+") do
        table.insert(words, word)
    end
    
    if #words == 0 then
        return "Unknown"
    elseif #words == 1 then
        return words[1]
    else
        -- Last word is surname, rest is first name(s)
        local surname = words[#words]
        local firstnames = {}
        for i = 1, #words - 1 do
            table.insert(firstnames, words[i])
        end
        return surname .. ", " .. table.concat(firstnames, " ")
    end
end

function GrimmorySync:hasGenre(genres, name)
    if not genres or not name then return false end
    local normalized_name = trim(tostring(name)):lower()
    if normalized_name == "" then return false end
    for _, genre in ipairs(genres) do
        if trim(tostring(genre or "")):lower() == normalized_name then return true end
    end
    return false
end

function GrimmorySync:sanitizePathComponent(str, sort_articles)
    if not str or str == "" then return "" end

    str = tostring(str):gsub("^%s+", ""):gsub("%s+$", "")
    if str == "" then return "" end

    if sort_articles ~= false then
        local article, rest
        article, rest = str:match("^(The)%s+(.+)$")
        if article and rest then
            str = rest .. ", " .. article
        else
            article, rest = str:match("^(A)%s+(.+)$")
            if article and rest then
                str = rest .. ", " .. article
            else
                article, rest = str:match("^(An)%s+(.+)$")
                if article and rest then
                    str = rest .. ", " .. article
                end
            end
        end
    end

    return str:gsub(":", "_"):gsub("/", "_"):gsub("\\", "_")
end

function GrimmorySync:normalizeTargetSubdir(subdir)
    if type(subdir) ~= "string" then return "" end

    subdir = subdir:gsub("\\", "/"):gsub("^%s+", ""):gsub("%s+$", "")
    subdir = subdir:gsub("^/+", ""):gsub("/+$", "")
    if subdir == "" then return "" end

    local parts = {}
    for part in subdir:gmatch("[^/]+") do
        local sanitized = self:sanitizePathComponent(part, false)
        if sanitized ~= "" and sanitized ~= "." and sanitized ~= ".." then
            parts[#parts + 1] = sanitized
        end
    end

    return table.concat(parts, "/")
end

function GrimmorySync:joinTargetPath(...)
    local parts = {}
    for i = 1, select("#", ...) do
        local part = self:normalizeTargetSubdir(select(i, ...))
        if part ~= "" then
            parts[#parts + 1] = part
        end
    end
    return table.concat(parts, "/")
end

function GrimmorySync:primaryGenre(book)
    for _, genre in ipairs(book.genres or {}) do
        local sanitized = self:sanitizePathComponent(genre, false)
        if sanitized ~= "" then
            return sanitized
        end
    end
    return ""
end

function GrimmorySync:authorSortName(book)
    return self:sanitizePathComponent(self:convertAuthorName(book.author) or "Unknown")
end

function GrimmorySync:seriesPathName(book)
    return self:sanitizePathComponent(book.series or "")
end

function GrimmorySync:flatTargetPath()
    return ""
end

function GrimmorySync:authorTargetPath(book)
    return self:authorSortName(book)
end

function GrimmorySync:genreSeriesTargetPath(book)
    local genre = self:primaryGenre(book)
    local series = self:seriesPathName(book)

    if genre ~= "" and series ~= "" then
        return self:joinTargetPath(genre, series)
    end
    return genre
end

function GrimmorySync:swedishGenreExampleTargetPath(book)
    local author_sort = self:authorSortName(book)
    local series = self:seriesPathName(book)

    if self:hasGenre(book.genres, "Serier") then
        if series == "" then
            return "Serier"
        else
            return "Serier/" .. series
        end
    elseif self:hasGenre(book.genres, "Manga") then
        if series == "" then
            return "Manga/Oneshots"
        else
            return "Manga/" .. series
        end
    elseif self:hasGenre(book.genres, "Light novel") then
        if series == "" then
            return "Light novels"
        else
            return "Light novels/" .. series
        end
    elseif self:hasGenre(book.genres, "Facklitteratur") then
        return "Facklitteratur"
    elseif self:hasGenre(book.genres, "Lyrik") then
        return "Lyrik"
    elseif self:hasGenre(book.genres, "Fiktion") then
        if series == "" then
            return "Fiktion"
        else
            return "Fiktion/" .. author_sort .. " - " .. series
        end
    end

    return ""
end

function GrimmorySync:pathRuleHelpers()
    return {
        has_genre = function(book, name)
            return self:hasGenre(book and book.genres, name)
        end,
        has_tag = function(book, name)
            return self:hasGenre(book and book.genres, name)
        end,
        has_author = function(book, name)
            return self:ruleValueMatches({
                book and book.author,
                self:authorSortName(book or {}),
            }, name)
        end,
        author_sort = function(book)
            return self:authorSortName(book or {})
        end,
        series = function(book)
            return self:seriesPathName(book or {})
        end,
        primary_genre = function(book)
            return self:primaryGenre(book or {})
        end,
        join = function(...)
            return self:joinTargetPath(...)
        end,
        sanitize = function(value)
            return self:sanitizePathComponent(value)
        end,
    }
end

function GrimmorySync:formatPathTemplate(template, book, helpers)
    if type(template) ~= "string" then return "" end
    local values = {
        author = helpers.author_sort(book),
        author_sort = helpers.author_sort(book),
        genre = helpers.primary_genre(book),
        series = helpers.series(book),
        title = self:sanitizePathComponent(book.title or ""),
    }
    return template:gsub("{([%w_]+)}", function(key)
        return values[key] or ""
    end)
end

function GrimmorySync:ruleValues(value)
    if value == nil then return nil end
    if type(value) == "table" then return value end
    return { value }
end

function GrimmorySync:ruleValueMatches(candidates, values)
    candidates = self:ruleValues(candidates)
    values = self:ruleValues(values)
    if not candidates or not values then return true end

    for _, candidate in ipairs(candidates) do
        local normalized_candidate = trim(tostring(candidate or "")):lower()
        if normalized_candidate ~= "" then
            for _, value in ipairs(values) do
                if normalized_candidate == trim(tostring(value or "")):lower() then
                    return true
                end
            end
        end
    end

    return false
end

function GrimmorySync:customRuleMatches(rule, book, helpers)
    if type(rule.when) == "function" then
        local ok, result = pcall(rule.when, book, helpers)
        return ok and result == true
    end

    local authors = rule.authors or rule.author or rule.author_sort
    if authors and not self:ruleValueMatches({
        book and book.author,
        helpers.author_sort(book),
    }, authors) then
        return false
    end

    local genres = rule.genres or rule.genre or rule.tags or rule.tag
    if type(genres) == "string" then
        genres = { genres }
    end
    if type(genres) == "table" then
        for _, genre in ipairs(genres) do
            if helpers.has_genre(book, genre) then
                return true
            end
        end
        return false
    end

    return true
end

function GrimmorySync:evaluateCustomRuleTable(rules, book, helpers)
    local rule_list = rules.rules or rules
    if type(rule_list) ~= "table" then return "" end

    for _, rule in ipairs(rule_list) do
        if type(rule) == "table" and self:customRuleMatches(rule, book, helpers) then
            if rule.series == true and helpers.series(book) == "" and rule.fallback then
                return self:formatPathTemplate(rule.fallback, book, helpers)
            end
            return self:formatPathTemplate(rule.path or rule.folder or "", book, helpers)
        end
    end

    return self:formatPathTemplate(rules.fallback or "", book, helpers)
end

function GrimmorySync:customTargetPath(book)
    local rules_path = self.path_rules_file or DEFAULT_PATH_RULES_FILE
    local ok, rules = pcall(dofile, rules_path)
    if not ok then
        logger.warn("[GrimmorySync] Could not load custom path rules:", rules_path, rules)
        return ""
    end

    local helpers = self:pathRuleHelpers()
    local ok_resolve, result
    if type(rules) == "function" then
        ok_resolve, result = pcall(rules, book, helpers)
    elseif type(rules) == "table" and type(rules.resolve) == "function" then
        ok_resolve, result = pcall(rules.resolve, book, helpers)
    elseif type(rules) == "table" then
        ok_resolve, result = pcall(function()
            return self:evaluateCustomRuleTable(rules, book, helpers)
        end)
    else
        logger.warn("[GrimmorySync] Custom path rules must return a function or table:", rules_path)
        return ""
    end

    if not ok_resolve then
        logger.warn("[GrimmorySync] Custom path rules failed:", result)
        return ""
    end

    return result or ""
end

function GrimmorySync:generateTargetPath(book)
    book = book or {}
    local profile = self.routing_profile or ROUTING_PROFILE_FLAT
    local target_subdir

    if profile == ROUTING_PROFILE_SWEDISH_EXAMPLE then
        target_subdir = self:swedishGenreExampleTargetPath(book)
    elseif profile == ROUTING_PROFILE_AUTHOR then
        target_subdir = self:authorTargetPath(book)
    elseif profile == ROUTING_PROFILE_GENRE_SERIES then
        target_subdir = self:genreSeriesTargetPath(book)
    elseif profile == ROUTING_PROFILE_CUSTOM then
        target_subdir = self:customTargetPath(book)
    else
        target_subdir = self:flatTargetPath(book)
    end

    return self:normalizeTargetSubdir(target_subdir)
end

function GrimmorySync:generatePossibleFilenames(book)
    -- Generate filename in the single unified format:
    -- "Last, First - Title.epub"
    -- Title already includes "Vol. X" for series books
    
    local filenames = {}
    
    local function sanitize(str)
        if not str or str == "" then return nil end
        -- Remove filesystem-unsafe chars but KEEP spaces and commas
        str = str:gsub('[:<>"|?*]', '')
        str = str:gsub('/', '-')
        str = str:gsub('^%s+', ''):gsub('%s+$', '')
        return str
    end
    
    local author = self:convertAuthorName(book.author)
    local safe_author = sanitize(author)
    local safe_title = sanitize(book.title)
    
    if not safe_title then return filenames end
    
    -- Single unified format: "Author - Title.epub"
    if safe_author then
        table.insert(filenames, string.format("%s - %s.epub", safe_author, safe_title))
    else
        -- Fallback if no author: add pattern for fuzzy matching
        -- This will match any "* - Title.epub" file
        table.insert(filenames, safe_title .. ".epub")  -- Exact match without author
        table.insert(filenames, " - " .. safe_title .. ".epub")  -- Pattern for fuzzy match
    end
    
    return filenames
end

function GrimmorySync:normalizeForComparison(str)
    -- Normalize string for comparison by removing accents and special chars
    if not str then return "" end
    
    -- Normalize quotes and apostrophes first (before other replacements)
    -- U+2019 (') right single quotation mark
    str = str:gsub("\226\128\153", "'")
    -- U+2018 (') left single quotation mark  
    str = str:gsub("\226\128\152", "'")
    -- U+201C (") left double quotation mark
    str = str:gsub("\226\128\156", '"')
    -- U+201D (") right double quotation mark
    str = str:gsub("\226\128\157", '"')
    -- U+2013 (–) en dash
    str = str:gsub("\226\128\147", "-")
    -- U+2014 (—) em dash
    str = str:gsub("\226\128\148", "-")
    
    -- Replace accented characters BEFORE lowercasing (handles uppercase special chars)
    local replacements = {
        -- Uppercase
        ["À"] = "A", ["Á"] = "A", ["Â"] = "A", ["Ã"] = "A", ["Ä"] = "A", ["Å"] = "A",
        ["È"] = "E", ["É"] = "E", ["Ê"] = "E", ["Ë"] = "E",
        ["Ì"] = "I", ["Í"] = "I", ["Î"] = "I", ["Ï"] = "I",
        ["Ò"] = "O", ["Ó"] = "O", ["Ô"] = "O", ["Õ"] = "O", ["Ö"] = "O", ["Ō"] = "O",
        ["Ù"] = "U", ["Ú"] = "U", ["Û"] = "U", ["Ü"] = "U", ["Ū"] = "U",
        ["Ý"] = "Y", ["Ÿ"] = "Y",
        ["Ñ"] = "N",
        ["Ç"] = "C",
        -- Lowercase
        ["à"] = "a", ["á"] = "a", ["â"] = "a", ["ã"] = "a", ["ä"] = "a", ["å"] = "a",
        ["è"] = "e", ["é"] = "e", ["ê"] = "e", ["ë"] = "e",
        ["ì"] = "i", ["í"] = "i", ["î"] = "i", ["ï"] = "i",
        ["ò"] = "o", ["ó"] = "o", ["ô"] = "o", ["õ"] = "o", ["ö"] = "o", ["ō"] = "o",
        ["ù"] = "u", ["ú"] = "u", ["û"] = "u", ["ü"] = "u", ["ū"] = "u",
        ["ý"] = "y", ["ÿ"] = "y",
        ["ñ"] = "n",
        ["ç"] = "c",
        ["_"] = "",  -- Remove underscores (used as replacement for special chars)
    }
    
    for char, replacement in pairs(replacements) do
        str = str:gsub(char, replacement)
    end
    
    -- Convert to lowercase AFTER removing accents
    str = str:lower()
    
    -- Normalize punctuation variations
    -- Remove comma before "vol." (e.g., "Title, Vol. 1" → "Title Vol. 1")
    str = str:gsub(",%s+vol%.", " vol.")
    -- Normalize colon spacing (e.g., "Title: Subtitle" vs "Title:Subtitle")
    str = str:gsub(":%s*", ": ")
    
    -- Normalize whitespace
    str = str:gsub("%s+", " ")
    str = str:gsub("^%s+", ""):gsub("%s+$", "")
    
    return str
end

function GrimmorySync:buildLocalBookIndex(local_books)
    local index = {
        lookup = {},
        files = {},
    }

    for _, book in ipairs(local_books) do
        -- Extract just the filename from the path (could be nested like "Author - Series/1 - Title.epub")
        local filename = book.filename:match("([^/]+)$") or book.filename
        local normalized = self:normalizeForComparison(filename)
        index.lookup[normalized] = book
        table.insert(index.files, {
            normalized = normalized,
            book = book,
        })
        logger.info("[GrimmorySync] Local file:", normalized)
    end

    return index
end

function GrimmorySync:findLocalMatch(remote, local_index)
    local possible_names = self:generatePossibleFilenames(remote)

    logger.info("[GrimmorySync] Checking remote book:", remote.title, "author:", remote.author or "none", "series:", remote.series or "none")
    for idx, pname in ipairs(possible_names) do
        logger.info("[GrimmorySync]   Possible name", idx, ":", pname)
    end

    for _, name in ipairs(possible_names) do
        local normalized = self:normalizeForComparison(name)
        local exact_match = local_index.lookup[normalized]

        if exact_match then
            return exact_match, name, false
        end

        -- Fuzzy match for title-only (when author is missing).
        if normalized:match("^ %-") then
            local pattern = normalized:gsub("^ %- ", ".* %- ")
            for _, local_file in ipairs(local_index.files) do
                if local_file.normalized:match(pattern .. "$") then
                    return local_file.book, local_file.normalized, true
                end
            end
        end
    end

    return nil, nil, false
end

function GrimmorySync:manifestKeyForPath(path)
    return path or ""
end

function GrimmorySync:metadataSignatureParts(remote)
    local genres = {}
    for _, genre in ipairs(remote.genres or {}) do
        genres[#genres + 1] = tostring(genre)
    end
    table.sort(genres)

    local parts = {
        remote.title or "",
        remote.author or "",
        remote.series or "",
        remote.series_index or "",
    }

    parts[#parts + 1] = remote.hardcover_id or ""
    parts[#parts + 1] = remote.hardcover_book_id or ""
    parts[#parts + 1] = remote.description or ""
    parts[#parts + 1] = table.concat(genres, "|")

    return parts
end

function GrimmorySync:remoteMetadataSignature(remote)
    return table.concat(self:metadataSignatureParts(remote), SIGNATURE_SEPARATOR)
end

function GrimmorySync:splitMetadataSignature(signature)
    local parts = {}
    if type(signature) ~= "string" or signature == "" then
        return parts
    end

    local start = 1
    while true do
        local sep_start, sep_end = signature:find(SIGNATURE_SEPARATOR, start, true)
        if not sep_start then
            parts[#parts + 1] = signature:sub(start)
            break
        end
        parts[#parts + 1] = signature:sub(start, sep_start - 1)
        start = sep_end + 1
    end

    return parts
end

function GrimmorySync:stableSignatureFromLegacy(signature)
    local parts = self:splitMetadataSignature(signature)
    if #parts < 10 then
        return nil
    end

    return table.concat({
        parts[4] or "",
        parts[5] or "",
        parts[6] or "",
        parts[7] or "",
        "",
        "",
        parts[9] or "",
        parts[10] or "",
    }, SIGNATURE_SEPARATOR)
end

function GrimmorySync:stableSignatureFromPreviousStable(signature)
    local parts = self:splitMetadataSignature(signature)
    if #parts ~= 6 then
        return nil
    end

    return table.concat({
        parts[1] or "",
        parts[2] or "",
        parts[3] or "",
        parts[4] or "",
        "",
        "",
        parts[5] or "",
        parts[6] or "",
    }, SIGNATURE_SEPARATOR)
end

function GrimmorySync:metadataSignatureMatches(manifest_entry, remote)
    if not manifest_entry or type(manifest_entry.signature) ~= "string" then
        return false, false
    end

    local current_signature = self:remoteMetadataSignature(remote)
    if manifest_entry.signature == current_signature then
        return true, false
    end

    if self:stableSignatureFromLegacy(manifest_entry.signature) == current_signature then
        return true, true
    end

    if self:stableSignatureFromPreviousStable(manifest_entry.signature) == current_signature then
        return true, true
    end

    return false, false
end

function GrimmorySync:migrateManifestSignature(manifest_entry, remote)
    if not manifest_entry then return end
    manifest_entry.signature = self:remoteMetadataSignature(remote)
    manifest_entry.updated = remote.updated
    manifest_entry.published = remote.published
    manifest_entry.download_url = remote.download_url
    manifest_entry.title = remote.title
    manifest_entry.author = remote.author
    manifest_entry.hardcover_id = remote.hardcover_id
    manifest_entry.hardcover_book_id = remote.hardcover_book_id
    manifest_entry.signature_migrated_at = os.time()
end

function GrimmorySync:getManifestEntry(manifest, path)
    local key = self:manifestKeyForPath(path)
    return manifest.books[key], key
end

function GrimmorySync:storeManifestEntry(manifest, path, remote)
    local key = self:manifestKeyForPath(path)
    manifest.books[key] = {
        signature = self:remoteMetadataSignature(remote),
        updated = remote.updated,
        published = remote.published,
        download_url = remote.download_url,
        title = remote.title,
        author = remote.author,
        hardcover_id = remote.hardcover_id,
        hardcover_book_id = remote.hardcover_book_id,
        refreshed_at = os.time(),
    }
end

function GrimmorySync:authorImagesPath()
    return (self.local_path or "/storage/emulated/0/ePubs"):gsub("/+$", "")
        .. "/.bookshelf-images/authors"
end

function GrimmorySync:bookshelfSlug(name)
    name = trim(name):lower()
    if name == "" then return "" end
    name = name:gsub("[,;:./%s_\\]+", "-")
    name = name:gsub("^%-+", ""):gsub("%-+$", "")
    return name
end

function GrimmorySync:safeExactImageStem(name)
    name = trim(name)
    if name == "" then return nil end
    local unsafe = { "/", "\\", ":", "<", ">", '"', "|", "?", "*" }
    for _, char in ipairs(unsafe) do
        if name:find(char, 1, true) then
            return nil
        end
    end
    return name
end

function GrimmorySync:safeSlugImageStem(name)
    name = trim(name)
    if name == "" then return nil end
    name = name:gsub("[/%\\:%<%>%\"%|%?%*]", "-")
    name = name:gsub("%-+", "-")
    name = name:gsub("^%-+", ""):gsub("%-+$", "")
    if name == "" then return nil end
    return name
end

function GrimmorySync:authorImageStems(author_name)
    local stems, seen = {}, {}

    local function addExact(name)
        local safe = self:safeExactImageStem(name)
        if safe and not seen[safe] then
            seen[safe] = true
            stems[#stems + 1] = safe
        end
    end

    local function addSlug(name)
        local slug = self:bookshelfSlug(name)
        slug = self:safeSlugImageStem(slug)
        if slug and not seen[slug] then
            seen[slug] = true
            stems[#stems + 1] = slug
        end
    end

    author_name = trim(author_name)
    if author_name == "" then return stems end

    addExact(author_name)
    addSlug(author_name)

    local converted = self:convertAuthorName(author_name)
    if converted and converted ~= "" and converted ~= author_name then
        addExact(converted)
        addSlug(converted)
    end

    return stems
end

function GrimmorySync:copyFile(src, dst)
    if src == dst then return true end

    local input = io.open(src, "rb")
    if not input then return false end
    local data = input:read("*a")
    input:close()

    local output = io.open(dst, "wb")
    if not output then return false end
    local ok = output:write(data)
    output:close()
    return ok and true or false
end

function GrimmorySync:imageExtensionFromHeaders(headers)
    local content_type
    for key, value in pairs(headers or {}) do
        if tostring(key):lower() == "content-type" then
            content_type = tostring(value):lower()
            break
        end
    end

    if content_type then
        if content_type:match("image/png") then return "png" end
        if content_type:match("image/webp") then return "webp" end
        if content_type:match("image/gif") then return "gif" end
        if content_type:match("image/bmp") then return "bmp" end
        if content_type:match("image/tiff") then return "tiff" end
        if content_type:match("image/jpeg") or content_type:match("image/jpg") then return "jpg" end
    end

    return "jpg"
end

function GrimmorySync:removeAuthorImageVariants(image_dir, stem, keep_ext)
    for _, ext in ipairs(AUTHOR_IMAGE_EXTS) do
        if ext ~= keep_ext then
            pcall(os.remove, image_dir .. "/" .. stem .. "." .. ext)
        end
    end
end

function GrimmorySync:authorImageExists(stems)
    local image_dir = self:authorImagesPath()
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")

    for _, stem in ipairs(stems or {}) do
        for _, ext in ipairs(AUTHOR_IMAGE_EXTS) do
            local path = image_dir .. "/" .. stem .. "." .. ext
            if ok_lfs then
                local ok_attr, attr = pcall(lfs.attributes, path)
                if ok_attr and attr and attr.mode == "file" and (attr.size == nil or attr.size > 0) then
                    return true, path
                end
            else
                local file = io.open(path, "rb")
                if file then
                    local has_data = file:read(1) ~= nil
                    file:close()
                    if has_data then
                        return true, path
                    end
                end
            end
        end
    end

    return false, nil
end

function GrimmorySync:apiAuthHeaders(token)
    local headers = {}
    if type(token) == "string" and token ~= "" then
        headers["authorization"] = "Bearer " .. token
    elseif self.username ~= "" and self.password ~= "" then
        local mime = require("mime")
        headers["authorization"] = "Basic " .. mime.b64(self.username .. ":" .. self.password)
    end
    return headers
end

function GrimmorySync:loginToGrimmoryApi()
    if self.username == "" or self.password == "" then
        return nil, _("Grimmory API sync requires username and password.")
    end

    local body = jsonObject({
        username = self.username,
        password = self.password,
    })

    local response, err = self:httpRequest(self:buildServerUrl("/api/v1/auth/login"), {
        method = "POST",
        body = body,
        headers = {
            ["accept"] = "application/json",
            ["content-type"] = "application/json",
        },
    })
    if err then
        return nil, err
    end

    local data, decode_err = jsonDecode(response)
    if not data then
        local token = response and response:match('"accessToken"%s*:%s*"([^"]+)"')
        if token and token ~= "" then
            return token, nil
        end
        return nil, decode_err
    end

    if type(data.accessToken) ~= "string" or data.accessToken == "" then
        return nil, _("No access token returned by Grimmory.")
    end

    return data.accessToken, nil
end

function GrimmorySync:extractBooksArray(data)
    local function asArray(candidate)
        if type(candidate) == "table" then
            if candidate[1] ~= nil or next(candidate) == nil then
                return candidate
            end
        end
        return nil
    end

    return asArray(data and data.books)
        or asArray(data and data.data)
        or asArray(data and data.content)
        or asArray(data and data.items)
        or asArray(data)
end

function GrimmorySync:bookApiId(book)
    if type(book) ~= "table" then
        return nil
    end

    local metadata = type(book.metadata) == "table" and book.metadata or nil
    return book.id or book.bookId or book.book_id or (metadata and (metadata.bookId or metadata.id))
end

function GrimmorySync:bookApiMetadata(book)
    if type(book) ~= "table" then
        return {}
    end
    return type(book.metadata) == "table" and book.metadata or book
end

function GrimmorySync:metadataFieldValue(value)
    local value_type = type(value)
    if value == nil then
        return ""
    elseif value_type == "string" then
        return trim(value)
    elseif value_type == "number" or value_type == "boolean" then
        return tostring(value)
    end
    return ""
end

function GrimmorySync:fetchBookMetadataFromGrimmoryApi(token)
    logger.info("[GrimmorySync] Fetching book metadata from Grimmory API")
    local headers = self:apiAuthHeaders(token)
    headers["accept"] = "application/json"

    local response, err = self:httpRequest(self:buildServerUrl("/api/v1/books?stripForListView=false"), {
        headers = headers,
    })
    if err then
        return nil, err
    end

    local data, decode_err = jsonDecode(response)
    if not data then
        local fallback_books = parseBookMetadataFallback(response)
        if #fallback_books > 0 then
            logger.info("[GrimmorySync] Parsed book metadata with fallback JSON parser:", #fallback_books)
            return fallback_books, nil
        end
        return nil, decode_err
    end

    local books = self:extractBooksArray(data)
    if not books then
        return nil, _("Could not find books array in Grimmory API response.")
    end

    return books, nil
end

function GrimmorySync:applyBookApiMetadata(remote_books, api_books)
    local by_id = {}
    for _, book in ipairs(api_books or {}) do
        local id = self:bookApiId(book)
        if id ~= nil then
            by_id[tostring(id)] = book
        end
    end

    local updated = 0
    for _, remote in ipairs(remote_books or {}) do
        local api_book = remote.book_id and by_id[tostring(remote.book_id)]
        if api_book then
            local metadata = self:bookApiMetadata(api_book)
            remote.hardcover_id = self:metadataFieldValue(metadata.hardcoverId)
            remote.hardcover_book_id = self:metadataFieldValue(metadata.hardcoverBookId)
            updated = updated + 1
        end
    end

    logger.info("[GrimmorySync] Enriched", updated, "books with Grimmory API metadata")
    return updated
end

function GrimmorySync:enrichRemoteBooksWithBookApiMetadata(remote_books)
    local token, login_err = self:loginToGrimmoryApi()
    if not token then
        logger.warn("[GrimmorySync] Book metadata API enrichment skipped:", login_err)
        return false, login_err
    end

    local api_books, err = self:fetchBookMetadataFromGrimmoryApi(token)
    if not api_books then
        logger.warn("[GrimmorySync] Book metadata API enrichment failed:", err)
        return false, err
    end

    local count = self:applyBookApiMetadata(remote_books, api_books)
    return true, count
end

function GrimmorySync:extractAuthorsArray(data)
    local function asArray(candidate)
        if type(candidate) == "table" then
            if candidate[1] ~= nil or next(candidate) == nil then
                return candidate
            end
        end
        return nil
    end

    return asArray(data and data.authors)
        or asArray(data and data.data)
        or asArray(data and data.content)
        or asArray(data and data.items)
        or asArray(data)
end

function GrimmorySync:fetchAuthorsFromGrimmory(token)
    logger.info("[GrimmorySync] Fetching authors for Bookshelf images")
    local headers = self:apiAuthHeaders(token)
    headers["accept"] = "application/json"

    local response, err = self:httpRequest(self:buildServerUrl("/api/v1/authors"), {
        headers = headers,
    })
    if err then
        return nil, err
    end

    local data, decode_err = jsonDecode(response)
    if not data then
        local fallback_authors = parseAuthorsFallback(response)
        if #fallback_authors > 0 then
            logger.info("[GrimmorySync] Parsed authors with fallback JSON parser:", #fallback_authors)
            return fallback_authors, nil
        end
        return nil, decode_err
    end

    local authors = self:extractAuthorsArray(data)
    if not authors then
        local fallback_authors = parseAuthorsFallback(response)
        if #fallback_authors > 0 then
            logger.info("[GrimmorySync] Parsed authors from unknown response shape:", #fallback_authors)
            return fallback_authors, nil
        end
        return nil, _("Could not find authors array in Grimmory response.")
    end

    logger.info("[GrimmorySync] Authors returned by Grimmory:", #authors)
    return authors, nil
end

function GrimmorySync:authorHasPhoto(author)
    if not author then return false end
    local value = author.hasPhoto
    if value == nil then value = author.has_photo end
    if value == nil then value = author.photo end
    return value == true or value == "true" or value == 1 or value == "1"
        or type(author.photoUrl) == "string"
        or type(author.thumbnailUrl) == "string"
        or type(author.imageUrl) == "string"
end

function GrimmorySync:authorDisplayName(author)
    return trim(author and (author.name or author.authorName or author.fullName or author.displayName))
end

function GrimmorySync:authorId(author)
    return author and (author.id or author.authorId)
end

function GrimmorySync:downloadAuthorImage(author, token)
    local id = self:authorId(author)
    local name = self:authorDisplayName(author)

    if not id or tostring(id) == "" or name == "" then
        return false, _("Author is missing id or name.")
    end

    local stems = self:authorImageStems(name)
    if #stems == 0 then
        return false, string.format(_("Could not create a Bookshelf image filename for %s"), name)
    end

    local image_dir = self:authorImagesPath()
    if not self:ensureDirectory(image_dir) then
        return false, _("Could not create Bookshelf author image directory.")
    end

    local tmp_path = image_dir .. "/.grimmory-author-" .. tostring(id) .. ".tmp"
    pcall(os.remove, tmp_path)

    local file = io.open(tmp_path, "wb")
    if not file then
        return false, _("Could not create temporary author image file.")
    end

    local image_url = "/api/v1/media/author/" .. tostring(id) .. "/photo"
    if type(token) == "string" and token ~= "" then
        image_url = image_url .. "?token=" .. urlEncode(token)
    end

    local response, err, status_code, response_headers = self:httpRequest(
        self:buildServerUrl(image_url),
        {
            sink = function(chunk, sink_err)
                if self.abort_sync then
                    return nil, "aborted"
                end
                if chunk then
                    local ok_write, write_err = file:write(chunk)
                    if not ok_write then
                        return nil, write_err
                    end
                elseif sink_err then
                    return nil, sink_err
                end
                return 1
            end,
            headers = self:apiAuthHeaders(token),
        }
    )
    file:close()

    if err then
        pcall(os.remove, tmp_path)
        return false, err .. (status_code and (" for " .. name) or "")
    end

    if self.abort_sync then
        pcall(os.remove, tmp_path)
        return false, ABORTED
    end

    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs then
        local attr = lfs.attributes(tmp_path)
        if not attr or attr.size == 0 then
            pcall(os.remove, tmp_path)
            return false, string.format(_("Downloaded author image was empty for %s"), name)
        end
    end

    local ext = self:imageExtensionFromHeaders(response_headers)
    local primary = image_dir .. "/" .. stems[1] .. "." .. ext
    pcall(os.remove, primary)
    local ok_rename, rename_err = os.rename(tmp_path, primary)
    if not ok_rename then
        pcall(os.remove, tmp_path)
        return false, rename_err or _("Could not save author image.")
    end
    self:removeAuthorImageVariants(image_dir, stems[1], ext)

    for i = 2, #stems do
        local alias = image_dir .. "/" .. stems[i] .. "." .. ext
        self:removeAuthorImageVariants(image_dir, stems[i])
        if not self:copyFile(primary, alias) then
            logger.warn("[GrimmorySync] Could not create author image alias:", alias)
        end
    end

    logger.info("[GrimmorySync] Synced author image:", name, "->", primary)
    return true, nil
end

function GrimmorySync:syncAuthorImagesAsync(done_callback)
    if self.sync_author_images == false then
        done_callback(true, { enabled = false })
        return
    end

    local ok, token_or_err, authors_or_err = pcall(function()
        self:showProgressDialog(_("Signing in for Bookshelf author images..."))
        local token, err = self:loginToGrimmoryApi()
        if not token then
            logger.warn("[GrimmorySync] Token login for author images failed; trying Basic auth:", err)
        end

        if self.abort_sync then
            return nil, ABORTED
        end

        self:showProgressDialog(_("Fetching authors from Grimmory..."))
        local authors, authors_err = self:fetchAuthorsFromGrimmory(token)
        if not authors then
            if err then
                authors_err = tostring(authors_err) .. " (token login failed: " .. tostring(err) .. ")"
            end
            return nil, authors_err
        end

        return token, authors
    end)

    if not ok then
        done_callback(false, { enabled = true, error = token_or_err })
        return
    end

    local token = token_or_err
    local authors = authors_or_err
    if type(authors) ~= "table" then
        done_callback(false, { enabled = true, error = authors or token or _("unknown error") })
        return
    end

    local queue = {}
    local skipped = 0
    local existing = 0
    for _, author in ipairs(authors) do
        if self:authorHasPhoto(author) then
            local name = self:authorDisplayName(author)
            local exists, existing_path = self:authorImageExists(self:authorImageStems(name))
            if exists then
                existing = existing + 1
                logger.info("[GrimmorySync] Author image already exists:", name, "->", existing_path)
            else
                queue[#queue + 1] = author
            end
        else
            skipped = skipped + 1
        end
    end

    if #queue == 0 then
        done_callback(true, {
            enabled = true,
            authors = #authors,
            synced = 0,
            existing = existing,
            skipped = skipped,
            failed = 0,
            path = self:authorImagesPath(),
        })
        return
    end

    local synced = 0
    local failed = 0
    local last_error
    local i = 0

    local function step()
        if self.abort_sync then
            done_callback(false, {
                enabled = true,
                error = ABORTED,
                authors = #authors,
                synced = synced,
                existing = existing,
                skipped = skipped,
                failed = failed,
                last_error = last_error,
                remaining = #queue - i,
                path = self:authorImagesPath(),
            })
            return
        end

        i = i + 1
        if i > #queue then
            done_callback(true, {
                enabled = true,
                authors = #authors,
                synced = synced,
                existing = existing,
                skipped = skipped,
                failed = failed,
                last_error = last_error,
                path = self:authorImagesPath(),
            })
            return
        end

        local author = queue[i]
        local name = self:authorDisplayName(author)
        self:showProgressDialog(string.format(
            _("Syncing author image %d of %d...\n\n%s\n\nUpdated: %d\nAlready existed: %d\nFailed: %d\n\nTap Cancel to stop after the current image."),
            i,
            #queue,
            name ~= "" and name or _("Unknown author"),
            synced,
            existing,
            failed
        ))

        UIManager:scheduleIn(PROGRESS_STEP_DELAY_S, function()
            local image_ok, image_err = self:downloadAuthorImage(author, token)
            if image_ok then
                synced = synced + 1
            else
                failed = failed + 1
                last_error = image_err
                logger.warn("[GrimmorySync] Author image sync failed:", image_err or "unknown")
            end
            UIManager:scheduleIn(PROGRESS_STEP_DELAY_S, step)
        end)
    end

    UIManager:scheduleIn(PROGRESS_STEP_DELAY_S, step)
end

function GrimmorySync:metadataRefreshMessage(stats, result, image_ok, image_result)
    result = result or {}

    local title
    if (result.refreshed or 0) == 0 then
        title = _("Metadata already up to date.")
    else
        title = _("Metadata updated.")
    end

    local message = string.format(
        _("%s\n\nLocal: %d books\nServer: %d books\nUpdated: %d books\nSkipped: %d books"),
        title,
        stats.local_count or 0,
        stats.remote_count or 0,
        result.refreshed or 0,
        result.skipped or 0
    )

    if image_result and image_result.enabled then
        if image_ok then
            message = message .. string.format(
                _("\n\nBookshelf author images: %d updated\nAlready existed: %d\nWithout image: %d\nFailed: %d"),
                image_result.synced or 0,
                image_result.existing or 0,
                image_result.skipped or 0,
                image_result.failed or 0
            )
            if (image_result.failed or 0) > 0 and image_result.last_error then
                message = message .. "\n" .. string.format(_("Latest error: %s"), tostring(image_result.last_error))
            end
        elseif image_result.error == ABORTED then
            message = message .. string.format(
                _("\n\nBookshelf author image sync canceled.\nUpdated: %d\nAlready existed: %d\nRemaining: %d"),
                image_result.synced or 0,
                image_result.existing or 0,
                image_result.remaining or 0
            )
        else
            message = message .. "\n\n"
                .. string.format(_("Bookshelf author images failed: %s"), tostring(image_result.error or _("unknown error")))
        end
    end

    return message
end

function GrimmorySync:compareAndDownload(local_books, remote_books)
    local local_index = self:buildLocalBookIndex(local_books)
    local manifest = self:loadManifest()
    local manifest_changed = false

    local missing = {}
    for _, remote in ipairs(remote_books) do
        local matched_book, matched_name, fuzzy = self:findLocalMatch(remote, local_index)

        if matched_book then
            if fuzzy then
                logger.info("[GrimmorySync] Already have:", remote.title, "(fuzzy matched:", matched_name, ")")
            else
                logger.info("[GrimmorySync] Already have:", remote.title, "(matched:", matched_name, ")")
            end
        else
            logger.info("[GrimmorySync] Missing book:", remote.title)
            table.insert(missing, remote)
        end
    end
    
    if #missing == 0 then
        return 0, nil
    end
    
    local count = 0
    for i, book in ipairs(missing) do
        if self.abort_sync then
            logger.info("[GrimmorySync] Sync aborted by user")
            return count, nil
        end
        
        self:showProgressDialog(string.format(
            _("Downloading book %d of %d...\n\n%s\n\nTap Cancel to stop after the current file."),
            i,
            #missing,
            book.title
        ))
        
        local downloaded, path = self:downloadBook(book)
        if downloaded then
            count = count + 1
            if path then
                self:storeManifestEntry(manifest, path, book)
                manifest_changed = true
                self:saveManifest(manifest)
            end
        end
    end

    if manifest_changed then
        self:saveManifest(manifest)
    end
    
    return count, nil
end

function GrimmorySync:buildMetadataRefreshQueue(local_books, remote_books)
    local local_index = self:buildLocalBookIndex(local_books)
    local manifest = self:loadManifest()
    local matched = {}
    local skipped = 0
    local manifest_changed = false

    for _, remote in ipairs(remote_books) do
        local matched_book, matched_name, fuzzy = self:findLocalMatch(remote, local_index)
        if matched_book and matched_book.path then
            local manifest_entry = self:getManifestEntry(manifest, matched_book.path)
            local signature_matches, should_migrate = self:metadataSignatureMatches(manifest_entry, remote)
            if signature_matches then
                skipped = skipped + 1
                if should_migrate then
                    self:migrateManifestSignature(manifest_entry, remote)
                    manifest_changed = true
                    logger.info("[GrimmorySync] Migrated stable metadata signature:", remote.title)
                end
                logger.info("[GrimmorySync] Metadata unchanged, skipping:", remote.title)
            else
                if fuzzy then
                    logger.info("[GrimmorySync] Will refresh:", remote.title, "(fuzzy matched:", matched_name, ")")
                else
                    logger.info("[GrimmorySync] Will refresh:", remote.title, "(matched:", matched_name, ")")
                end
                table.insert(matched, {
                    remote = remote,
                    local_path = matched_book.path,
                })
            end
        end
    end

    if manifest_changed then
        self:saveManifest(manifest)
    end

    return matched, skipped, manifest
end

function GrimmorySync:refreshExistingMetadata(local_books, remote_books)
    local matched, skipped, manifest = self:buildMetadataRefreshQueue(local_books, remote_books)

    if #matched == 0 then
        return 0, nil, skipped
    end

    local count = 0
    for i, item in ipairs(matched) do
        if self.abort_sync then
            logger.info("[GrimmorySync] Metadata refresh aborted by user")
            self:saveManifest(manifest)
            return count, nil, skipped
        end

        self:showProgressDialog(string.format(
            _("Refreshing metadata %d of %d...\n\n%s\n\nSkipped unchanged: %d\n\nTap Cancel to stop after the current file."),
            i,
            #matched,
            item.remote.title,
            skipped
        ))

        if self:downloadBook(item.remote, item.local_path, { record_history = false }) then
            count = count + 1
            self:storeManifestEntry(manifest, item.local_path, item.remote)
            self:saveManifest(manifest)
        end
    end

    self:saveManifest(manifest)
    return count, nil, skipped
end

function GrimmorySync:refreshExistingMetadataAsync(matched, skipped, manifest, done_callback)
    local total = #matched
    local count = 0
    local i = 0
    manifest = manifest or self:loadManifest()

    if total == 0 then
        done_callback(true, { refreshed = 0, skipped = skipped or 0, remaining = 0 })
        return
    end

    local function finish(success, result)
        self:saveManifest(manifest)
        done_callback(success, result)
    end

    local function step()
        if self.abort_sync then
            logger.info("[GrimmorySync] Metadata refresh aborted by user")
            finish(false, {
                error = ABORTED,
                refreshed = count,
                skipped = skipped or 0,
                remaining = total - count,
            })
            return
        end

        i = i + 1
        if i > total then
            finish(true, {
                refreshed = count,
                skipped = skipped or 0,
                remaining = 0,
            })
            return
        end

        local item = matched[i]
        self:showProgressDialog(string.format(
            _("Refreshing metadata %d of %d...\n\n%s\n\nUpdated: %d\nSkipped unchanged: %d\n\nTap Cancel to stop after the current file."),
            i,
            total,
            item.remote.title,
            count,
            skipped or 0
        ))

        UIManager:scheduleIn(PROGRESS_STEP_DELAY_S, function()
            if self.abort_sync then
                UIManager:scheduleIn(0, step)
                return
            end

            local downloaded = self:downloadBook(item.remote, item.local_path, { record_history = false })
            if downloaded then
                count = count + 1
                self:storeManifestEntry(manifest, item.local_path, item.remote)
                self:saveManifest(manifest)
            end

            UIManager:scheduleIn(PROGRESS_STEP_DELAY_S, step)
        end)
    end

    UIManager:scheduleIn(PROGRESS_STEP_DELAY_S, step)
end

function GrimmorySync:buildCalibrePath(book)
    -- Simply use generatePossibleFilenames to get the single unified format
    local possible = self:generatePossibleFilenames(book)
    local filename = possible[1] or (book.title .. ".epub")
    local full_path = self.local_path .. "/" .. filename
    
    return full_path, self.local_path, filename
end

function GrimmorySync:downloadBook(book, target_path, options)
    options = options or {}

    local ok_http, http = pcall(require, "socket.http")
    local ok_https, https = pcall(require, "ssl.https")
    local ok_ltn12, ltn12 = pcall(require, "ltn12")
    
    if not ok_http or not ok_ltn12 then
        logger.err("[GrimmorySync] Cannot load HTTP libraries")
        return false
    end
    
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then
        logger.err("[GrimmorySync] Cannot load lfs")
        return false
    end
    
    logger.info("[GrimmorySync] Downloading:", book.title)

    -- Create directory structure recursively
    local function ensureDir(path)
        -- Handle absolute paths (starting with /)
        local is_absolute = path:match("^/")
        
        local parts = {}
        for part in path:gmatch("[^/]+") do
            table.insert(parts, part)
        end
        
        local current = is_absolute and "" or nil
        for _, part in ipairs(parts) do
            if current == nil then
                current = part
            elseif current == "" then
                -- First part after root /
                current = "/" .. part
            else
                current = current .. "/" .. part
            end
            
            local attr = lfs.attributes(current)
            if not attr then
                local ok, err = lfs.mkdir(current)
                if not ok then
                    logger.err("[GrimmorySync] Cannot create directory:", current, "error:", err or "unknown")
                    return false
                end
                logger.info("[GrimmorySync] Created directory:", current)
            end
        end
        return true
    end

    -- Determine full path
    local full_path, dir_path, display_path
    if target_path and target_path ~= "" then
        full_path = target_path
        dir_path = full_path:match("(.+)/[^/]+$") or self.local_path
        display_path = full_path
    else
        -- Generate target directory path based on genres/series
        local target_subdir = self:generateTargetPath(book)

        -- Generate all possible filenames and use the first one as default
        -- This ensures downloaded files match what we search for
        local possible_names = self:generatePossibleFilenames(book)
        local filename_only = possible_names[1] or (book.title .. ".epub")

        -- Combine subdirectory and filename
        if target_subdir and target_subdir ~= "" then
            display_path = target_subdir .. "/" .. filename_only
        else
            display_path = filename_only
        end

        if display_path:match("/") then
            full_path = self.local_path .. "/" .. display_path
            dir_path = full_path:match("(.+)/[^/]+$") or self.local_path
        else
            full_path = self.local_path .. "/" .. display_path
            dir_path = self.local_path
        end
    end

    logger.info("[GrimmorySync] Target path:", display_path)

    -- Create directories
    if not ensureDir(dir_path) then
        return false
    end
    
    -- Prepare download URL
    local download_url = self:buildServerUrl(book.download_url)
    logger.info("[GrimmorySync] Download URL:", download_url)
    
    -- Prepare HTTP headers
    local headers = {}
    if self.username ~= "" and self.password ~= "" then
        local mime = require("mime")
        headers["authorization"] = "Basic " .. mime.b64(self.username .. ":" .. self.password)
    end
    
    local tmp_path = full_path .. ".grimmorytmp"
    local backup_path = full_path .. ".grimmorybak"
    pcall(os.remove, tmp_path)
    pcall(os.remove, backup_path)

    -- Open a temporary file first so failed downloads do not corrupt the existing EPUB.
    local file = io.open(tmp_path, "wb")
    if not file then
        logger.err("[GrimmorySync] Cannot create:", tmp_path)
        return false
    end
    local file_closed = false
    local function closeFile()
        if not file_closed then
            file:close()
            file_closed = true
        end
    end
    local function abortableSink(chunk, err)
        if self.abort_sync then
            closeFile()
            return nil, "aborted"
        end
        if chunk then
            local ok_write, write_err = file:write(chunk)
            if not ok_write then
                closeFile()
                return nil, write_err
            end
        elseif err then
            closeFile()
            return nil, err
        else
            closeFile()
        end
        return 1
    end
    
    -- Download using appropriate protocol
    local request_func = download_url:match("^https://") and (ok_https and https.request or http.request) or http.request
    
    local success, status_code, response_headers = request_func{
        url = download_url,
        sink = abortableSink,
        headers = headers,
    }
    closeFile()
    
    -- Check result
    if not success or (type(status_code) == "number" and status_code ~= 200) then
        logger.err("[GrimmorySync] Download failed:", status_code or "unknown error")
        pcall(os.remove, tmp_path)
        return false
    end
    if self.abort_sync then
        logger.info("[GrimmorySync] Download aborted by user")
        pcall(os.remove, tmp_path)
        return false
    end
    
    -- Verify file was created and has content
    local attr = lfs.attributes(tmp_path)
    if not attr or attr.size == 0 then
        logger.err("[GrimmorySync] Downloaded file is empty or missing")
        pcall(os.remove, tmp_path)
        return false
    end

    local existing_attr = lfs.attributes(full_path)
    if existing_attr then
        local ok_rename, rename_err = os.rename(full_path, backup_path)
        if not ok_rename then
            logger.err("[GrimmorySync] Cannot backup existing file:", full_path, "error:", rename_err or "unknown")
            pcall(os.remove, tmp_path)
            return false
        end
    end

    local ok_replace, replace_err = os.rename(tmp_path, full_path)
    if not ok_replace then
        logger.err("[GrimmorySync] Cannot move downloaded file into place:", full_path, "error:", replace_err or "unknown")
        if existing_attr then
            pcall(os.rename, backup_path, full_path)
        end
        pcall(os.remove, tmp_path)
        return false
    end

    if existing_attr then
        pcall(os.remove, backup_path)
    end

    logger.info("[GrimmorySync] OK:", book.title, "(" .. attr.size .. " bytes)")
    if options.record_history ~= false then
        self:recordDownload(book, full_path)
    end
    return true, full_path
end

function GrimmorySync:requestAbort(message)
    self.abort_sync = true
    if self.abort_notified then return end
    self.abort_notified = true
    self:closeProgressDialog()
    UIManager:show(InfoMessage:new{
        text = message or _("Stopping after the current download..."),
        timeout = 2,
    })
end

function GrimmorySync:showProgressDialog(text)
    -- Always close and create new dialog since InfoMessage doesn't have setText
    if self.progress_dialog then
        self:closeProgressDialog()
    end

    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        title = text,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        self:requestAbort(_("Sync will stop after the current file..."))
                    end,
                },
            },
        },
    }
    self.progress_dialog = dialog
    UIManager:show(self.progress_dialog)
    UIManager:forceRePaint()
end

function GrimmorySync:closeProgressDialog()
    if self.progress_dialog then
        local dialog = self.progress_dialog
        self.progress_dialog = nil
        pcall(function() UIManager:close(dialog) end)
        if UIManager.forceRePaint then
            UIManager:forceRePaint()
        end
    end
end

function GrimmorySync:startSync()
    if self.server_url == "" then
        local config_dialog
        config_dialog = ConfirmBox:new{
            text = _("Server not configured!\n\nConfigure now?"),
            ok_text = _("Configure"),
            ok_callback = function()
                pcall(function() UIManager:close(config_dialog) end)
                UIManager:scheduleIn(0, function()
                    self:showServerConfig()
                end)
            end,
        }
        UIManager:show(config_dialog)
        return
    end
    
    -- Reset abort flag
    self.abort_sync = false
    self.abort_notified = false
    
    -- Show confirmation with cancel option
    local confirm_dialog
    confirm_dialog = ConfirmBox:new{
        text = _("Sync missing books?\n\nOnly books missing from this device will be downloaded. You can cancel at any time."),
        ok_text = _("Start"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            pcall(function() UIManager:close(confirm_dialog) end)
            UIManager:scheduleIn(0, function()
                self:performSync()
            end)
        end,
    }
    UIManager:show(confirm_dialog)
end

function GrimmorySync:startMetadataRefresh()
    if self.server_url == "" then
        local config_dialog
        config_dialog = ConfirmBox:new{
            text = _("Server not configured!\n\nConfigure now?"),
            ok_text = _("Configure"),
            ok_callback = function()
                pcall(function() UIManager:close(config_dialog) end)
                UIManager:scheduleIn(0, function()
                    self:showServerConfig()
                end)
            end,
        }
        UIManager:show(config_dialog)
        return
    end

    self.abort_sync = false
    self.abort_notified = false

    local confirm_dialog
    confirm_dialog = ConfirmBox:new{
        text = _("Refresh metadata in existing books?\n\nThe plugin will download matched EPUB files again from Grimmory and replace local files only after the download has been verified. Missing books are not downloaded here."),
        ok_text = _("Refresh"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            pcall(function() UIManager:close(confirm_dialog) end)
            UIManager:scheduleIn(0, function()
                self:performMetadataRefresh()
            end)
        end,
    }
    UIManager:show(confirm_dialog)
end

function GrimmorySync:performSync()
    self:showProgressDialog(_("Scanning local books..."))
    
    local ok, success, count_or_err = pcall(function()
        local local_books = self:scanLocalBooks()
        logger.info("[GrimmorySync] Local books found:", #local_books)
        
        if self.abort_sync then
            return false, ABORTED
        end
        
        self:showProgressDialog(string.format(
            _("Fetching books from server...\n\nLocal books: %d\n\nTap Cancel to stop after the current step."),
            #local_books
        ))
        
        local remote_books, err = self:fetchBooklistFromGrimmory()
        
        if not remote_books then
            return false, err
        end
        
        if self.abort_sync then
            return false, ABORTED
        end
        
        logger.info("[GrimmorySync] Remote books found:", #remote_books)

        self:showProgressDialog(_("Fetching extra metadata from Grimmory..."))
        local enriched, enrich_result = self:enrichRemoteBooksWithBookApiMetadata(remote_books)
        if enriched then
            logger.info("[GrimmorySync] Book API metadata applied:", enrich_result)
        else
            logger.warn("[GrimmorySync] Continuing without Book API metadata:", enrich_result)
        end

        if self.abort_sync then
            return false, ABORTED
        end
        
        self:showProgressDialog(string.format(
            _("Comparing and downloading...\n\nLocal: %d\nServer: %d\n\nTap Cancel to stop after the current file."),
            #local_books,
            #remote_books
        ))
        
        local count, err = self:compareAndDownload(local_books, remote_books)
        return true, {downloaded = count, local_count = #local_books, remote_count = #remote_books}
    end)
    
    self:closeProgressDialog()
    
    if not ok then
        UIManager:show(InfoMessage:new{
            text = string.format(_("Sync error: %s"), tostring(success)),
            timeout = 5,
        })
        logger.err("[GrimmorySync] Sync error:", success)
        return
    end
    
    if not success then
        if count_or_err ~= ABORTED then
            UIManager:show(InfoMessage:new{
                text = string.format(_("Error: %s"), tostring(count_or_err)),
                timeout = 5,
            })
            logger.err("[GrimmorySync] Error:", count_or_err)
        end
        return
    end
    
    local stats = count_or_err
    local message = string.format(
        _("Sync complete.\n\nLocal: %d books\nServer: %d books\nDownloaded missing: %d books"),
        stats.local_count or 0,
        stats.remote_count or 0,
        stats.downloaded or 0
    )
    
    UIManager:show(InfoMessage:new{
        text = message,
        timeout = 5,
    })
end

function GrimmorySync:performMetadataRefresh()
    self:showProgressDialog(_("Scanning local books..."))

    local ok, success, payload = pcall(function()
        local local_books = self:scanLocalBooks()
        logger.info("[GrimmorySync] Local books found:", #local_books)

        if self.abort_sync then
            return false, ABORTED
        end

        self:showProgressDialog(string.format(
            _("Fetching books from server...\n\nLocal books: %d\n\nTap Cancel to stop after the current step."),
            #local_books
        ))

        local remote_books, err = self:fetchBooklistFromGrimmory()

        if not remote_books then
            return false, err
        end

        if self.abort_sync then
            return false, ABORTED
        end

        logger.info("[GrimmorySync] Remote books found:", #remote_books)

        self:showProgressDialog(_("Fetching extra metadata from Grimmory..."))
        local enriched, enrich_result = self:enrichRemoteBooksWithBookApiMetadata(remote_books)
        if enriched then
            logger.info("[GrimmorySync] Book API metadata applied:", enrich_result)
        else
            logger.warn("[GrimmorySync] Continuing without Book API metadata:", enrich_result)
        end

        if self.abort_sync then
            return false, ABORTED
        end

        self:showProgressDialog(string.format(
            _("Matching existing books...\n\nLocal: %d\nServer: %d"),
            #local_books,
            #remote_books
        ))

        local matched, skipped, manifest = self:buildMetadataRefreshQueue(local_books, remote_books)

        return true, {
            matched = matched,
            manifest = manifest,
            skipped = skipped or 0,
            local_count = #local_books,
            remote_count = #remote_books,
        }
    end)

    self:closeProgressDialog()

    if not ok then
        self:closeProgressDialog()
        UIManager:show(InfoMessage:new{
            text = string.format(_("Metadata refresh error: %s"), tostring(success)),
            timeout = 5,
        })
        logger.err("[GrimmorySync] Metadata refresh error:", success)
        return
    end

    if not success then
        self:closeProgressDialog()
        if payload ~= ABORTED then
            UIManager:show(InfoMessage:new{
                text = string.format(_("Error: %s"), tostring(payload)),
                timeout = 5,
            })
            logger.err("[GrimmorySync] Metadata refresh error:", payload)
        end
        return
    end

    local stats = payload
    local matched = stats.matched or {}

    local function finishWithAuthorImages(result)
        self:closeProgressDialog()

        if self.sync_author_images == false then
            UIManager:show(InfoMessage:new{
                text = self:metadataRefreshMessage(stats, result),
                timeout = 5,
            })
            return
        end

        self:syncAuthorImagesAsync(function(image_ok, image_result)
            self:closeProgressDialog()
            UIManager:show(InfoMessage:new{
                text = self:metadataRefreshMessage(stats, result, image_ok, image_result),
                timeout = 5,
            })
        end)
    end

    if #matched == 0 then
        finishWithAuthorImages({
            refreshed = 0,
            skipped = stats.skipped or 0,
        })
        return
    end

    self:refreshExistingMetadataAsync(matched, stats.skipped or 0, stats.manifest, function(done_ok, result)
        self:closeProgressDialog()
        result = result or {}
        if not done_ok then
            if result.error == ABORTED then
                UIManager:show(InfoMessage:new{
                    text = string.format(
                        _("Metadata refresh canceled.\n\nUpdated: %d books\nRemaining: %d books"),
                        result.refreshed or 0,
                        result.remaining or 0
                    ),
                    timeout = 5,
                })
            else
                UIManager:show(InfoMessage:new{
                    text = string.format(_("Error: %s"), tostring(result.error or _("unknown"))),
                    timeout = 5,
                })
                logger.err("[GrimmorySync] Metadata refresh error:", result.error)
            end
            return
        end

        finishWithAuthorImages(result)
    end)
end

function GrimmorySync:showStatus()
    local books = self:scanLocalBooks()
    local sync_source = (self.selected_feed and self.selected_feed ~= "")
        and (self.selected_feed_label ~= "" and self.selected_feed_label or self.selected_feed)
        or _("All books")
    local text = string.format(
        _("Server: %s\nUser: %s\nPath: %s\nLocal: %d books\nSync source: %s\nFolder profile: %s\nCustom rules: %s\nBookshelf author images: %s\nBookshelf image path: %s"),
        self.server_url ~= "" and self.server_url or _("Not set"),
        self.username ~= "" and self.username or _("Not set"),
        self.local_path,
        #books,
        sync_source,
        self:routingProfileLabel(self.routing_profile or ROUTING_PROFILE_FLAT),
        self.path_rules_file or DEFAULT_PATH_RULES_FILE,
        self.sync_author_images ~= false and _("on") or _("off"),
        self:authorImagesPath()
    )
    
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = 5,
    })
end

return GrimmorySync

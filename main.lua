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
local MAX_HISTORY = 15
local PROGRESS_STEP_DELAY_S = 0.2
local AUTHOR_IMAGE_EXTS = { "jpg", "jpeg", "png", "gif", "bmp", "webp", "tiff", "tif" }

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
        return nil, "Cannot load JSON parser"
    end

    local ok_decode, data = pcall(json.decode, body)
    if not ok_decode or type(data) ~= "table" then
        return nil, "Could not parse JSON response"
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

function GrimmorySync:loadSettings()
    local file = io.open(SETTINGS_FILE, "r") or io.open(LEGACY_SETTINGS_FILE, "r")
    if not file then
        return {
            server_url = "",
            username = "",
            password = "",
            local_path = "/storage/emulated/0/ePubs",
            sync_author_images = true,
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
    
    return {
        server_url = settings.server_url or "",
        username = settings.username or "",
        password = settings.password or "",
        local_path = settings.local_path or "/storage/emulated/0/ePubs",
        sync_author_images = settingToBool(settings.sync_author_images, true),
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
        title = book.title or "Okänd titel",
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
                text = _("Inga nedladdningar ännu"),
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
        text = _("Rensa historik"),
        callback = function(touchmenu_instance)
            self:runAfterMenuClose(touchmenu_instance, function()
                UIManager:show(ConfirmBox:new{
                    text = _("Rensa hela nedladdningshistoriken?"),
                    ok_text = _("Rensa"),
                    cancel_text = _("Avbryt"),
                    ok_callback = function()
                        self:saveHistory({})
                        UIManager:show(InfoMessage:new{
                            text = _("Historiken rensad."),
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
            text = _("Kan inte kontrollera filen."),
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
            text = _("Filen hittades inte:\n") .. (entry.path or "okänd sökväg"),
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
                text = _("Sync author images during metadata refresh"),
                checked_func = function()
                    return self.sync_author_images ~= false
                end,
                keep_menu_open = true,
                callback = function()
                    self.sync_author_images = not (self.sync_author_images ~= false)
                    self:saveSettings()
                    UIManager:show(InfoMessage:new{
                        text = self.sync_author_images
                            and _("Author image sync enabled")
                            or _("Author image sync disabled"),
                        timeout = 2,
                    })
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
                text = _("Senaste böckerna"),
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
        input_hint = "/storage/emulated/0/ePubs",
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
                            text = _("✓ Configuration saved!"),
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
        return nil, "Cannot load HTTP libraries"
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
        return body, "Connection failed: " .. tostring(status_code), status_code, response_headers
    end

    if status_num and (status_num < 200 or status_num >= 300) then
        return body, "HTTP " .. status_code, status_code, response_headers
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
            return nil, "OPDS endpoint requires authentication but credentials were rejected (401). Please verify username and password."
        end
    end
    
    if not root_response then
        return nil, err
    end
    
    -- Find the "All Books" catalog link
    local catalog_link
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
    
    if not catalog_link then
        return nil, "Could not find 'All Books' catalog link in OPDS feed"
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
                logger.info("[GrimmorySync] Found book:", title, "by", author or "Unknown", "series:", series or "none", "->", download_link)
                table.insert(books, {
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

function GrimmorySync:generateTargetPath(book)
    -- Generate target directory path based on genres and series
    -- Follows the same logic as Calibre save template
    
    local function hasGenre(genres, name)
        if not genres then return false end
        for _, genre in ipairs(genres) do
            if genre == name then return true end
        end
        return false
    end
    
    local function sanitizeForPath(str)
        if not str or str == "" then return str end
        
        -- Trim leading/trailing whitespace (including newlines from XML parsing)
        str = str:gsub("^%s+", ""):gsub("%s+$", "")
        if str == "" then return str end
        
        -- Move leading articles to the end (for proper sorting)
        -- "The Bugle Call" → "Bugle Call, The"
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
        
        -- Replace colon with underscore (Android/KOReader doesn't support colons in folder names)
        str = str:gsub(":", "_")
        
        return str
    end
    
    local author_sort = self:convertAuthorName(book.author) or "Unknown"
    local series = book.series
    local series_index = book.series_index
    
    -- Sanitize series name for use in paths
    if series and series ~= "" then
        series = sanitizeForPath(series)
    end
    if author_sort and author_sort ~= "" then
        author_sort = sanitizeForPath(author_sort)
    end
    
    -- Check genres in priority order
    if hasGenre(book.genres, "Serier") then
        if not series or series == "" then
            return "Serier"
        else
            return "Serier/" .. series
        end
    elseif hasGenre(book.genres, "Manga") then
        if not series or series == "" then
            return "Manga/Oneshots"
        else
            return "Manga/" .. series
        end
    elseif hasGenre(book.genres, "Light novel") then
        if not series or series == "" then
            return "Light novels"
        else
            return "Light novels/" .. series
        end
    elseif hasGenre(book.genres, "Facklitteratur") then
        return "Facklitteratur"
    elseif hasGenre(book.genres, "Lyrik") then
        return "Lyrik"
    elseif hasGenre(book.genres, "Fiktion") then
        if not series or series == "" then
            return "Fiktion"
        else
            return "Fiktion/" .. author_sort .. " - " .. series
        end
    else
        -- No matching genre - place in root ePubs directory
        return ""
    end
end

function GrimmorySync:generatePossibleFilenames(book)
    -- Generate filename in the single unified format:
    -- "Efternamn, Förnamn - Titel.epub"
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

function GrimmorySync:remoteMetadataSignature(remote)
    local genres = {}
    for _, genre in ipairs(remote.genres or {}) do
        genres[#genres + 1] = tostring(genre)
    end
    table.sort(genres)

    return table.concat({
        remote.updated or "",
        remote.published or "",
        remote.download_url or "",
        remote.title or "",
        remote.author or "",
        remote.series or "",
        remote.series_index or "",
        remote.year or "",
        remote.description or "",
        table.concat(genres, "|"),
    }, "\31")
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
        return nil, "Author image sync requires Grimmory username and password."
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
        return nil, "No access token returned by Grimmory."
    end

    return data.accessToken, nil
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
        return nil, "Could not find authors array in Grimmory response."
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
        return false, "Author is missing id or name."
    end

    local stems = self:authorImageStems(name)
    if #stems == 0 then
        return false, "Could not create a Bookshelf image filename for " .. name
    end

    local image_dir = self:authorImagesPath()
    if not self:ensureDirectory(image_dir) then
        return false, "Could not create Bookshelf author image directory."
    end

    local tmp_path = image_dir .. "/.grimmory-author-" .. tostring(id) .. ".tmp"
    pcall(os.remove, tmp_path)

    local file = io.open(tmp_path, "wb")
    if not file then
        return false, "Could not create temporary author image file."
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
        return false, "Avbruten"
    end

    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs then
        local attr = lfs.attributes(tmp_path)
        if not attr or attr.size == 0 then
            pcall(os.remove, tmp_path)
            return false, "Downloaded author image was empty for " .. name
        end
    end

    local ext = self:imageExtensionFromHeaders(response_headers)
    local primary = image_dir .. "/" .. stems[1] .. "." .. ext
    pcall(os.remove, primary)
    local ok_rename, rename_err = os.rename(tmp_path, primary)
    if not ok_rename then
        pcall(os.remove, tmp_path)
        return false, rename_err or "Could not save author image."
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
        self:showProgressDialog("Loggar in för författarbilder...")
        local token, err = self:loginToGrimmoryApi()
        if not token then
            logger.warn("[GrimmorySync] Token login for author images failed; trying Basic auth:", err)
        end

        if self.abort_sync then
            return nil, "Avbruten"
        end

        self:showProgressDialog("Hämtar författare från Grimmory...")
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
        done_callback(false, { enabled = true, error = authors or token or "unknown error" })
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
                error = "Avbruten",
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
            "Synkar författarbild %d av %d...\n\n%s\n\nUppdaterade: %d\nRedan fanns: %d\nMisslyckade: %d\n\nTryck Avbryt för att stoppa efter pågående bild.",
            i,
            #queue,
            name ~= "" and name or "Okänd författare",
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
        title = "✓ Metadata redan aktuell!"
    else
        title = "✓ Metadata uppdaterad!"
    end

    local message = string.format(
        "%s\n\nLokala: %d böcker\nServern: %d böcker\nUppdaterade: %d böcker\nHoppade över: %d böcker",
        title,
        stats.local_count or 0,
        stats.remote_count or 0,
        result.refreshed or 0,
        result.skipped or 0
    )

    if image_result and image_result.enabled then
        if image_ok then
            message = message .. string.format(
                "\n\nFörfattarbilder: %d uppdaterade\nRedan fanns: %d\nUtan bild: %d\nMisslyckade: %d",
                image_result.synced or 0,
                image_result.existing or 0,
                image_result.skipped or 0,
                image_result.failed or 0
            )
            if (image_result.failed or 0) > 0 and image_result.last_error then
                message = message .. "\nSenaste fel: " .. tostring(image_result.last_error)
            end
        elseif image_result.error == "Avbruten" then
            message = message .. string.format(
                "\n\nFörfattarbildsynk avbruten.\nUppdaterade: %d\nRedan fanns: %d\nKvar: %d",
                image_result.synced or 0,
                image_result.existing or 0,
                image_result.remaining or 0
            )
        else
            message = message .. "\n\nFörfattarbilder misslyckades: "
                .. tostring(image_result.error or "unknown error")
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
            "Laddar ner bok %d av %d...\n\n%s\n\nTryck Avbryt för att stoppa efter pågående fil.",
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

    for _, remote in ipairs(remote_books) do
        local matched_book, matched_name, fuzzy = self:findLocalMatch(remote, local_index)
        if matched_book and matched_book.path then
            local manifest_entry = self:getManifestEntry(manifest, matched_book.path)
            local remote_signature = self:remoteMetadataSignature(remote)
            if manifest_entry and manifest_entry.signature == remote_signature then
                skipped = skipped + 1
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
            "Uppdaterar metadata %d av %d...\n\n%s\n\nHoppade över oförändrade: %d\n\nTryck Avbryt för att stoppa efter pågående fil.",
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
                error = "Avbruten",
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
            "Uppdaterar metadata %d av %d...\n\n%s\n\nUppdaterade: %d\nHoppade över oförändrade: %d\n\nTryck Avbryt för att stoppa efter pågående fil.",
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
        text = message or _("Avbryter efter pågående nedladdning..."),
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
                    text = _("Avbryt"),
                    callback = function()
                        self:requestAbort(_("Synken avbryts efter pågående fil..."))
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
        text = _("Synka saknade böcker?\n\nEndast böcker som saknas på enheten laddas ner. Du kan avbryta när som helst."),
        ok_text = _("Starta"),
        cancel_text = _("Avbryt"),
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
        text = _("Uppdatera metadata i befintliga böcker?\n\nPluginet laddar om matchade EPUB-filer från Grimmory och ersätter lokala filer först efter att nedladdningen har verifierats. Saknade böcker laddas inte ner här."),
        ok_text = _("Uppdatera"),
        cancel_text = _("Avbryt"),
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
    self:showProgressDialog("Skannar lokala böcker...")
    
    local ok, success, count_or_err = pcall(function()
        local local_books = self:scanLocalBooks()
        logger.info("[GrimmorySync] Local books found:", #local_books)
        
        if self.abort_sync then
            return false, "Avbruten"
        end
        
        self:showProgressDialog(string.format(
            "Hämtar böcker från server...\n\nLokala böcker: %d\n\nTryck Avbryt för att stoppa efter pågående steg.",
            #local_books
        ))
        
        local remote_books, err = self:fetchBooklistFromGrimmory()
        
        if not remote_books then
            return false, err
        end
        
        if self.abort_sync then
            return false, "Avbruten"
        end
        
        logger.info("[GrimmorySync] Remote books found:", #remote_books)
        
        self:showProgressDialog(string.format(
            "Jämför och laddar ner...\n\nLokala: %d\nServern: %d\n\nTryck Avbryt för att stoppa efter pågående fil.",
            #local_books,
            #remote_books
        ))
        
        local count, err = self:compareAndDownload(local_books, remote_books)
        return true, {downloaded = count, local_count = #local_books, remote_count = #remote_books}
    end)
    
    self:closeProgressDialog()
    
    if not ok then
        UIManager:show(InfoMessage:new{
            text = _("Sync error: ") .. tostring(success),
            timeout = 5,
        })
        logger.err("[GrimmorySync] Sync error:", success)
        return
    end
    
    if not success then
        if count_or_err ~= "Avbruten" then
            UIManager:show(InfoMessage:new{
                text = _("Error: ") .. tostring(count_or_err),
                timeout = 5,
            })
            logger.err("[GrimmorySync] Error:", count_or_err)
        end
        return
    end
    
    local stats = count_or_err
    local message = string.format(
        "✓ Synk klar!\n\nLokala: %d böcker\nServern: %d böcker\nNedladdade saknade: %d böcker",
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
    self:showProgressDialog("Skannar lokala böcker...")

    local ok, success, payload = pcall(function()
        local local_books = self:scanLocalBooks()
        logger.info("[GrimmorySync] Local books found:", #local_books)

        if self.abort_sync then
            return false, "Avbruten"
        end

        self:showProgressDialog(string.format(
            "Hämtar böcker från server...\n\nLokala böcker: %d\n\nTryck Avbryt för att stoppa efter pågående steg.",
            #local_books
        ))

        local remote_books, err = self:fetchBooklistFromGrimmory()

        if not remote_books then
            return false, err
        end

        if self.abort_sync then
            return false, "Avbruten"
        end

        logger.info("[GrimmorySync] Remote books found:", #remote_books)

        self:showProgressDialog(string.format(
            "Matchar befintliga böcker...\n\nLokala: %d\nServern: %d",
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
            text = _("Metadata refresh error: ") .. tostring(success),
            timeout = 5,
        })
        logger.err("[GrimmorySync] Metadata refresh error:", success)
        return
    end

    if not success then
        self:closeProgressDialog()
        if payload ~= "Avbruten" then
            UIManager:show(InfoMessage:new{
                text = _("Error: ") .. tostring(payload),
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
            if result.error == "Avbruten" then
                UIManager:show(InfoMessage:new{
                    text = string.format(
                        "Metadatauppdatering avbruten.\n\nUppdaterade: %d böcker\nKvar: %d böcker",
                        result.refreshed or 0,
                        result.remaining or 0
                    ),
                    timeout = 5,
                })
            else
                UIManager:show(InfoMessage:new{
                    text = _("Error: ") .. tostring(result.error or "unknown"),
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
    local text = string.format(
        "Server: %s\nUser: %s\nPath: %s\nLocal: %d books\nAuthor images: %s\nAuthor image path: %s",
        self.server_url ~= "" and self.server_url or "Not set",
        self.username ~= "" and self.username or "Not set",
        self.local_path,
        #books,
        self.sync_author_images ~= false and "on" or "off",
        self:authorImagesPath()
    )
    
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = 5,
    })
end

return GrimmorySync

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local dump = require("dump")
local Updater = require("grimmory_updater")
local Providers = require("providers/init")

local GrimmorySync = WidgetContainer:new{
    name = "grimmorysync",
    is_doc_only = false,
    abort_sync = false,
    abort_notified = false,
}

local ANDROID_KOREADER_DIR = "/storage/emulated/0/koreader"
local ANDROID_LIBRARY_DIR = "/storage/emulated/0/ePubs"

local function isAndroid()
    return pcall(require, "android")
end

local function dataStoragePath(method_name, fallback)
    local ok_datastorage, datastorage = pcall(require, "datastorage")
    if ok_datastorage and datastorage and type(datastorage[method_name]) == "function" then
        local ok_path, path = pcall(datastorage[method_name], datastorage)
        if ok_path and type(path) == "string" and path ~= "" then
            return path:gsub("/+$", "")
        end
    end
    return fallback:gsub("/+$", "")
end

local DATA_DIR = dataStoragePath("getFullDataDir", dataStoragePath("getDataDir", ANDROID_KOREADER_DIR))
local SETTINGS_DIR = dataStoragePath("getSettingsDir", ANDROID_KOREADER_DIR)

local function dataPath(filename)
    return DATA_DIR .. "/" .. filename
end

local function settingsPath(filename)
    return SETTINGS_DIR .. "/" .. filename
end

local function androidLegacyPath(filename)
    return ANDROID_KOREADER_DIR .. "/" .. filename
end

local function openFirstReadable(paths)
    local seen = {}
    for _, path in ipairs(paths) do
        if path and not seen[path] then
            seen[path] = true
            local file = io.open(path, "r")
            if file then
                return file, path
            end
        end
    end
    return nil, nil
end

local SETTINGS_FILE = settingsPath("library_sync_settings.txt")
local SETTINGS_READ_FILES = {
    SETTINGS_FILE,
    androidLegacyPath("library_sync_settings.txt"),
    settingsPath("grimmory_sync_settings.txt"),
    androidLegacyPath("grimmory_sync_settings.txt"),
    settingsPath("booklore_sync_settings.txt"),
    androidLegacyPath("booklore_sync_settings.txt"),
}
local HISTORY_FILE = settingsPath("library_sync_history.lua")
local HISTORY_READ_FILES = {
    HISTORY_FILE,
    androidLegacyPath("library_sync_history.lua"),
    settingsPath("grimmory_sync_history.lua"),
    androidLegacyPath("grimmory_sync_history.lua"),
    settingsPath("booklore_sync_history.lua"),
    androidLegacyPath("booklore_sync_history.lua"),
}
local MANIFEST_FILE = settingsPath("library_sync_manifest.lua")
local MANIFEST_READ_FILES = {
    MANIFEST_FILE,
    androidLegacyPath("library_sync_manifest.lua"),
    settingsPath("grimmory_sync_manifest.lua"),
    androidLegacyPath("grimmory_sync_manifest.lua"),
}
local DEFAULT_LOCAL_PATH = isAndroid() and ANDROID_LIBRARY_DIR or DATA_DIR
local DEFAULT_PATH_RULES_FILE = dataPath("library_sync_path_rules.lua")
local MAX_HISTORY = 15
local PROGRESS_STEP_DELAY_S = 0.2
local AUTHOR_IMAGE_EXTS = { "jpg", "jpeg", "png", "gif", "bmp", "webp", "tiff", "tif" }
local MIRROR_TRASH_DIR = ".library-sync-trash"
local SIGNATURE_SEPARATOR = "\31"
local ABORTED = "aborted"
local SERVER_GRIMMORY = "grimmory"
local SERVER_BOOKORBIT = "bookorbit"
local ROUTING_PROFILE_FLAT = "flat"
local ROUTING_PROFILE_AUTHOR = "author"
local ROUTING_PROFILE_GENRE_SERIES = "genre_series"
local ROUTING_PROFILE_CUSTOM = "custom"
local ROUTING_PROFILE_SWEDISH_EXAMPLE = "swedish_genre_example"
local LEGACY_ROUTING_PROFILE_SWEDISH_EXAMPLE = "robin_legacy"
local FILENAME_PROFILE_GRIMMORY = "grimmory_file"
local FILENAME_PROFILE_SYNC_DEFAULT = "sync_default"
local FILENAME_PROFILE_CALIBRE_TITLE_AUTHORS = "calibre_title_authors"
local ROUTING_PROFILE_LIST = {
    { id = ROUTING_PROFILE_FLAT, label = _("Library root") },
    { id = ROUTING_PROFILE_AUTHOR, label = _("Author folders") },
    { id = ROUTING_PROFILE_GENRE_SERIES, label = _("Genre/series folders") },
    { id = ROUTING_PROFILE_CUSTOM, label = _("Custom rules file") },
    { id = ROUTING_PROFILE_SWEDISH_EXAMPLE, label = _("Swedish genre example") },
}
local FILENAME_PROFILE_LIST = {
    { id = FILENAME_PROFILE_GRIMMORY, label = _("Server file name") },
    { id = FILENAME_PROFILE_SYNC_DEFAULT, label = _("Library Sync default") },
    { id = FILENAME_PROFILE_CALIBRE_TITLE_AUTHORS, label = _("Calibre title-authors") },
}
local AUTO_REFRESH_INTERVAL_LIST = {
    { hours = 0, label = _("Off") },
    { hours = 1, label = _("Every hour") },
    { hours = 3, label = _("Every 3 hours") },
    { hours = 6, label = _("Every 6 hours") },
    { hours = 12, label = _("Every 12 hours") },
    { hours = 24, label = _("Daily") },
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

local function settingToNumber(value, default)
    local number = tonumber(value)
    if number == nil then
        return default
    end
    return number
end

local function isRoutingProfile(value)
    for _, profile in ipairs(ROUTING_PROFILE_LIST) do
        if profile.id == value then
            return true
        end
    end
    return false
end

local function isFilenameProfile(value)
    for _, profile in ipairs(FILENAME_PROFILE_LIST) do
        if profile.id == value then
            return true
        end
    end
    return false
end

local function normalizeAutoRefreshInterval(value)
    local hours = tonumber(value) or 0
    for _, interval in ipairs(AUTO_REFRESH_INTERVAL_LIST) do
        if interval.hours == hours then
            return interval.hours
        end
    end
    return 0
end

local function trim(str)
    if type(str) ~= "string" then return "" end
    return str:gsub("^%s+", ""):gsub("%s+$", "")
end

local function unicodeChar(code)
    code = tonumber(code)
    if not code then return "" end
    if code < 0x80 then
        return string.char(code)
    elseif code < 0x800 then
        return string.char(
            0xC0 + math.floor(code / 0x40),
            0x80 + (code % 0x40)
        )
    elseif code < 0x10000 then
        return string.char(
            0xE0 + math.floor(code / 0x1000),
            0x80 + (math.floor(code / 0x40) % 0x40),
            0x80 + (code % 0x40)
        )
    end
    return ""
end

local function xmlDecode(value)
    if type(value) ~= "string" then return nil end
    value = value:gsub("&amp;", "&")
        :gsub("&apos;", "'")
        :gsub("&#39;", "'")
        :gsub("&quot;", '"')
        :gsub("&lt;", "<")
        :gsub("&gt;", ">")
    value = value:gsub("&#x(%x+);", function(hex)
        return unicodeChar(tonumber(hex, 16))
    end)
    value = value:gsub("&#(%d+);", function(decimal)
        return unicodeChar(decimal)
    end)
    return value
end

local function xmlText(value)
    if type(value) ~= "string" then return nil end
    value = value:gsub("<!%[CDATA%[(.-)%]%]>", "%1")
    value = value:gsub("<[^>]+>", "")
    value = xmlDecode(value) or value
    value = value:gsub("%s+", " ")
    value = trim(value)
    return value ~= "" and value or nil
end

local function xmlAttr(attrs, name)
    if type(attrs) ~= "string" then return nil end
    local quoted = attrs:match(name .. '%s*=%s*"([^"]*)"')
        or attrs:match(name .. "%s*=%s*'([^']*)'")
    return quoted and xmlDecode(quoted) or nil
end

local function urlDecode(value)
    if type(value) ~= "string" then return nil end
    return value:gsub("+", " "):gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)
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

local function responseHeader(headers, name)
    if type(headers) ~= "table" then
        return nil
    end
    local wanted = tostring(name or ""):lower()
    for key, value in pairs(headers) do
        if tostring(key):lower() == wanted then
            return value
        end
    end
    return nil
end

local function resolveRedirectUrl(current_url, location)
    if type(location) ~= "string" or location == "" then
        return nil
    end
    location = trim(location)
    if location:match("^https?://") then
        return location
    end

    local scheme, host, path = current_url:match("^(https?)://([^/]+)(/.*)$")
    if not scheme then
        scheme, host = current_url:match("^(https?)://([^/]+)$")
        path = "/"
    end
    if not scheme or not host then
        return nil
    end

    if location:sub(1, 2) == "//" then
        return scheme .. ":" .. location
    end
    if location:sub(1, 1) == "/" then
        return scheme .. "://" .. host .. location
    end

    local base_path = path:gsub("[^/]*$", "")
    return scheme .. "://" .. host .. base_path .. location
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
        :gsub("\\b", "\b")
        :gsub("\\f", "\f")
        :gsub("\\r", "")
        :gsub("\\t", "\t")
        :gsub('\\"', '"')
        :gsub("\\/", "/")
        :gsub("\\\\", "\\")
    return value
end

local JSON_NULL = {}

local function parseJsonFallback(body)
    if type(body) ~= "string" then
        return nil
    end

    local pos = 1
    local length = #body

    local function char()
        return body:sub(pos, pos)
    end

    local function skipWhitespace()
        while pos <= length and body:sub(pos, pos):match("%s") do
            pos = pos + 1
        end
    end

    local parseValue

    local function parseString()
        if char() ~= '"' then
            return nil
        end
        pos = pos + 1
        local parts = {}
        local start = pos

        while pos <= length do
            local current = char()
            if current == '"' then
                parts[#parts + 1] = body:sub(start, pos - 1)
                pos = pos + 1
                return decodeJsonString(table.concat(parts))
            elseif current == "\\" then
                parts[#parts + 1] = body:sub(start, pos - 1)
                local unicode_escape = body:sub(pos, pos + 5)
                if unicode_escape:match("^\\u%x%x%x%x$") then
                    parts[#parts + 1] = unicode_escape
                    pos = pos + 6
                else
                    local escaped = body:sub(pos, pos + 1)
                    parts[#parts + 1] = escaped
                    pos = pos + 2
                end
                start = pos
            else
                pos = pos + 1
            end
        end

        return nil
    end

    local function parseNumber()
        local start = pos
        if char() == "-" then
            pos = pos + 1
        end

        if char() == "0" then
            pos = pos + 1
        else
            if not char():match("%d") then
                return nil
            end
            while pos <= length and char():match("%d") do
                pos = pos + 1
            end
        end

        if char() == "." then
            pos = pos + 1
            if not char():match("%d") then
                return nil
            end
            while pos <= length and char():match("%d") do
                pos = pos + 1
            end
        end

        local exponent = char()
        if exponent == "e" or exponent == "E" then
            pos = pos + 1
            local sign = char()
            if sign == "+" or sign == "-" then
                pos = pos + 1
            end
            if not char():match("%d") then
                return nil
            end
            while pos <= length and char():match("%d") do
                pos = pos + 1
            end
        end

        return tonumber(body:sub(start, pos - 1))
    end

    local function parseArray()
        if char() ~= "[" then
            return nil
        end
        pos = pos + 1
        skipWhitespace()

        local result = {}
        if char() == "]" then
            pos = pos + 1
            return result
        end

        while pos <= length do
            local value = parseValue()
            if value == nil then
                return nil
            end
            result[#result + 1] = value
            skipWhitespace()

            local separator = char()
            if separator == "]" then
                pos = pos + 1
                return result
            elseif separator ~= "," then
                return nil
            end
            pos = pos + 1
            skipWhitespace()
        end

        return nil
    end

    local function parseObject()
        if char() ~= "{" then
            return nil
        end
        pos = pos + 1
        skipWhitespace()

        local result = {}
        if char() == "}" then
            pos = pos + 1
            return result
        end

        while pos <= length do
            local key = parseString()
            if key == nil then
                return nil
            end
            skipWhitespace()
            if char() ~= ":" then
                return nil
            end
            pos = pos + 1
            skipWhitespace()

            local value = parseValue()
            if value == nil then
                return nil
            end
            result[key] = value
            skipWhitespace()

            local separator = char()
            if separator == "}" then
                pos = pos + 1
                return result
            elseif separator ~= "," then
                return nil
            end
            pos = pos + 1
            skipWhitespace()
        end

        return nil
    end

    function parseValue()
        skipWhitespace()
        local current = char()
        if current == "{" then
            return parseObject()
        elseif current == "[" then
            return parseArray()
        elseif current == '"' then
            return parseString()
        elseif current == "-" or current:match("%d") then
            return parseNumber()
        elseif body:sub(pos, pos + 3) == "true" then
            pos = pos + 4
            return true
        elseif body:sub(pos, pos + 4) == "false" then
            pos = pos + 5
            return false
        elseif body:sub(pos, pos + 3) == "null" then
            pos = pos + 4
            return JSON_NULL
        end
        return nil
    end

    local result = parseValue()
    skipWhitespace()
    if result == nil or pos <= length then
        return nil
    end
    return result
end

local function jsonDecode(body)
    for _, module_name in ipairs({ "json", "dkjson", "cjson", "rapidjson" }) do
        local ok_json, json = pcall(require, module_name)
        if ok_json and json and type(json.decode) == "function" then
            local ok_decode, data = pcall(json.decode, body)
            if ok_decode and type(data) == "table" then
                return data, nil
            end
        end
    end

    local fallback_data = parseJsonFallback(body)
    if type(fallback_data) == "table" then
        return fallback_data, nil
    end
    return nil, _("Could not parse JSON response")
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
    local file, settings_path = openFirstReadable(SETTINGS_READ_FILES)
    if not file then
        return {
            server_type = "",
            server_url = "",
            username = "",
            password = "",
            api_username = "",
            api_password = "",
            api_credentials_migrated = true,
            local_path = DEFAULT_LOCAL_PATH,
            sync_author_images = false,
            routing_profile = ROUTING_PROFILE_FLAT,
            path_rules_file = DEFAULT_PATH_RULES_FILE,
            filename_profile = FILENAME_PROFILE_GRIMMORY,
            selected_feed = "",
            selected_feed_label = "",
            mirror_selected_sync_source = false,
            auto_refresh_on_startup = false,
            auto_refresh_interval_hours = 0,
            auto_refresh_use_opds_updated = false,
            auto_refresh_last_check = 0,
            settings_source_path = nil,
            settings_needs_migration = false,
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

    local filename_profile = settings.filename_profile
    if filename_profile == nil or filename_profile == "" then
        filename_profile = FILENAME_PROFILE_SYNC_DEFAULT
    elseif not isFilenameProfile(filename_profile) then
        filename_profile = FILENAME_PROFILE_SYNC_DEFAULT
    end

    local server_type = settings.server_type
    local settings_needs_migration = not Providers.isValid(server_type)
    if settings_needs_migration then
        -- Settings written before multi-server support always belong to Grimmory.
        server_type = SERVER_GRIMMORY
    end

    local api_username = settings.api_username or ""
    local api_password = settings.api_password or ""
    local api_credentials_migrated = settingToBool(settings.api_credentials_migrated, false)
    if server_type == SERVER_GRIMMORY
        and not api_credentials_migrated
        and api_username == ""
        and api_password == ""
        and (settings.username or "") ~= ""
        and (settings.password or "") ~= "" then
        -- Older Grimmory-only settings used the OPDS credentials for both
        -- catalogue access and API enrichment. Keep that behavior until the
        -- user explicitly configures separate Grimmory account credentials.
        api_username = settings.username or ""
        api_password = settings.password or ""
        settings_needs_migration = true
    end
    
    return {
        server_type = server_type,
        server_url = settings.server_url or "",
        username = settings.username or "",
        password = settings.password or "",
        api_username = api_username,
        api_password = api_password,
        api_credentials_migrated = true,
        local_path = settings.local_path or DEFAULT_LOCAL_PATH,
        sync_author_images = settingToBool(settings.sync_author_images, true),
        routing_profile = routing_profile,
        path_rules_file = settings.path_rules_file or DEFAULT_PATH_RULES_FILE,
        filename_profile = filename_profile,
        selected_feed = settings.selected_feed or "",
        selected_feed_label = settings.selected_feed_label or "",
        mirror_selected_sync_source = settingToBool(settings.mirror_selected_sync_source, false),
        auto_refresh_on_startup = settingToBool(settings.auto_refresh_on_startup, false),
        auto_refresh_interval_hours = normalizeAutoRefreshInterval(settings.auto_refresh_interval_hours),
        auto_refresh_use_opds_updated = settingToBool(settings.auto_refresh_use_opds_updated, false),
        auto_refresh_last_check = settingToNumber(settings.auto_refresh_last_check, 0),
        settings_source_path = settings_path,
        settings_needs_migration = settings_needs_migration,
    }
end

function GrimmorySync:saveSettings()
    local file = io.open(SETTINGS_FILE, "w")
    if not file then
        logger.warn("[GrimmorySync] Cannot save settings:", SETTINGS_FILE)
        return false
    end
    
    file:write("server_type=" .. (self.server_type or SERVER_GRIMMORY) .. "\n")
    file:write("server_url=" .. self.server_url .. "\n")
    file:write("username=" .. self.username .. "\n")
    file:write("password=" .. self.password .. "\n")
    file:write("api_username=" .. (self.api_username or "") .. "\n")
    file:write("api_password=" .. (self.api_password or "") .. "\n")
    file:write("api_credentials_migrated=true\n")
    file:write("local_path=" .. self.local_path .. "\n")
    file:write("sync_author_images=" .. boolToSetting(self.sync_author_images ~= false) .. "\n")
    file:write("routing_profile=" .. (self.routing_profile or ROUTING_PROFILE_FLAT) .. "\n")
    file:write("path_rules_file=" .. (self.path_rules_file or DEFAULT_PATH_RULES_FILE) .. "\n")
    file:write("filename_profile=" .. (self.filename_profile or FILENAME_PROFILE_SYNC_DEFAULT) .. "\n")
    file:write("selected_feed=" .. (self.selected_feed or "") .. "\n")
    file:write("selected_feed_label=" .. (self.selected_feed_label or "") .. "\n")
    file:write("mirror_selected_sync_source=" .. boolToSetting(self.mirror_selected_sync_source == true) .. "\n")
    file:write("auto_refresh_on_startup=" .. boolToSetting(self.auto_refresh_on_startup == true) .. "\n")
    file:write("auto_refresh_interval_hours=" .. tostring(self.auto_refresh_interval_hours or 0) .. "\n")
    file:write("auto_refresh_use_opds_updated=" .. boolToSetting(self.auto_refresh_use_opds_updated == true) .. "\n")
    file:write("auto_refresh_last_check=" .. tostring(self.auto_refresh_last_check or 0) .. "\n")
    file:close()
    return true
end

function GrimmorySync:loadHistory()
    for _, path in ipairs(HISTORY_READ_FILES) do
        local ok, history = pcall(dofile, path)
        if ok and type(history) == "table" then
            return history
        end
    end

    return {}
end

function GrimmorySync:saveHistory(history)
    local file = io.open(HISTORY_FILE, "w")
    if not file then
        logger.warn("[GrimmorySync] Cannot save history:", HISTORY_FILE)
        return
    end
    file:write("return " .. dump(history) .. "\n")
    file:close()
end

function GrimmorySync:loadManifest()
    for _, path in ipairs(MANIFEST_READ_FILES) do
        local ok, manifest = pcall(dofile, path)
        if ok and type(manifest) == "table" then
            manifest.books = type(manifest.books) == "table" and manifest.books or {}
            return manifest
        end
    end

    return {
        version = 1,
        books = {},
    }
end

function GrimmorySync:saveManifest(manifest)
    local file = io.open(MANIFEST_FILE, "w")
    if not file then
        logger.warn("[GrimmorySync] Cannot save manifest:", MANIFEST_FILE)
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

function GrimmorySync:autoRefreshIntervalLabel(hours)
    hours = normalizeAutoRefreshInterval(hours)
    for _, interval in ipairs(AUTO_REFRESH_INTERVAL_LIST) do
        if interval.hours == hours then
            return interval.label
        end
    end
    return AUTO_REFRESH_INTERVAL_LIST[1].label
end

function GrimmorySync:autoRefreshIntervalSeconds()
    local hours = normalizeAutoRefreshInterval(self.auto_refresh_interval_hours)
    if hours <= 0 then
        return 0
    end
    return hours * 60 * 60
end

function GrimmorySync:automaticMetadataRefreshEnabled()
    return (self.auto_refresh_on_startup == true or self:autoRefreshIntervalSeconds() > 0)
        and self:configurationReady()
end

function GrimmorySync:cancelAutomaticMetadataRefreshTimer()
    if self.auto_refresh_timer then
        UIManager:unschedule(self.auto_refresh_timer)
        self.auto_refresh_timer = nil
    end
end

function GrimmorySync:nextAutomaticMetadataRefreshDelay()
    if self.auto_refresh_startup_pending and self.auto_refresh_on_startup == true then
        return 10, "startup"
    end

    local interval = self:autoRefreshIntervalSeconds()
    if interval <= 0 then
        return nil, nil
    end

    local last_check = tonumber(self.auto_refresh_last_check) or 0
    if last_check <= 0 then
        return interval, "interval"
    end

    local elapsed = os.time() - last_check
    return math.max(10, interval - elapsed), "interval"
end

function GrimmorySync:scheduleAutomaticMetadataRefresh(delay, reason)
    self:cancelAutomaticMetadataRefreshTimer()
    if not delay or delay <= 0 then
        return
    end

    self.auto_refresh_timer = function()
        self.auto_refresh_timer = nil
        self:performAutomaticMetadataRefresh(reason)
    end

    UIManager:scheduleIn(delay, self.auto_refresh_timer)
    logger.info("[GrimmorySync] Scheduled automatic metadata refresh in", delay, "seconds")
end

function GrimmorySync:configureAutomaticMetadataRefresh()
    self:cancelAutomaticMetadataRefreshTimer()
    if not self:automaticMetadataRefreshEnabled() then
        return
    end

    local delay, reason = self:nextAutomaticMetadataRefreshDelay()
    if delay then
        self:scheduleAutomaticMetadataRefresh(delay, reason)
    end
end

function GrimmorySync:onResume()
    self:configureAutomaticMetadataRefresh()
end

function GrimmorySync:onSuspend()
    self:cancelAutomaticMetadataRefreshTimer()
end

function GrimmorySync:init()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    self:onDispatcherRegisterActions()
    self:registerFileDialogButtons()
    
    local settings = self:loadSettings()
    self.server_type = settings.server_type
    self.server_url = settings.server_url
    self.username = settings.username
    self.password = settings.password
    self.api_username = settings.api_username or ""
    self.api_password = settings.api_password or ""
    self.local_path = settings.local_path
    self.sync_author_images = settings.sync_author_images ~= false
    self.routing_profile = settings.routing_profile
    self.path_rules_file = settings.path_rules_file
    self.filename_profile = settings.filename_profile
    self.selected_feed = settings.selected_feed or ""
    self.selected_feed_label = settings.selected_feed_label or ""
    self.mirror_selected_sync_source = settings.mirror_selected_sync_source == true
    self.auto_refresh_on_startup = settings.auto_refresh_on_startup == true
    self.auto_refresh_interval_hours = normalizeAutoRefreshInterval(settings.auto_refresh_interval_hours)
    self.auto_refresh_use_opds_updated = settings.auto_refresh_use_opds_updated == true
    self.auto_refresh_last_check = settings.auto_refresh_last_check or 0
    self.auto_refresh_startup_pending = self.auto_refresh_on_startup == true
    self.auto_refresh_running = false
    self.sync_running = false
    if settings.settings_needs_migration
        or (settings.settings_source_path and settings.settings_source_path ~= SETTINGS_FILE) then
        self:saveSettings()
    end
    self:configureAutomaticMetadataRefresh()
end

function GrimmorySync:provider()
    return Providers.get(self.server_type)
end

function GrimmorySync:serverName()
    if not Providers.isValid(self.server_type) then
        return _("Not set")
    end
    return self:provider().name
end

function GrimmorySync:apiCredentials()
    local provider = self:provider()
    if provider.api_credentials_separate then
        return trim(self.api_username or ""), trim(self.api_password or "")
    end
    return trim(self.username or ""), trim(self.password or "")
end

function GrimmorySync:apiCredentialCandidates()
    local provider = self:provider()
    local candidates = {}
    local seen = {}

    local function add(username, password, label)
        username = trim(username or "")
        password = trim(password or "")
        if username == "" or password == "" then
            return
        end
        local key = username .. SIGNATURE_SEPARATOR .. password
        if seen[key] then
            return
        end
        seen[key] = true
        candidates[#candidates + 1] = {
            username = username,
            password = password,
            label = label,
        }
    end

    local api_username, api_password = self:apiCredentials()
    add(api_username, api_password, "account")

    if provider.api_credentials_separate and provider.api_fallback_to_opds_credentials then
        add(self.username, self.password, "OPDS")
    end

    return candidates
end

function GrimmorySync:configurationReady()
    return Providers.isValid(self.server_type) and trim(self.server_url or "") ~= ""
end

function GrimmorySync:promptConfiguration()
    local config_dialog
    config_dialog = ConfirmBox:new{
        text = _("Server not configured!\n\nConfigure now?"),
        ok_text = _("Configure"),
        ok_callback = function()
            pcall(function() UIManager:close(config_dialog) end)
            UIManager:scheduleIn(0, function()
                self:showServerTypeConfig()
            end)
        end,
    }
    UIManager:show(config_dialog)
end

function GrimmorySync:onDispatcherRegisterActions()
    local ok_dispatcher, Dispatcher = pcall(require, "dispatcher")
    if not ok_dispatcher or not Dispatcher then
        return
    end

    Dispatcher:registerAction("grimmory_sync_missing_books", {
        category = "none",
        event = "GrimmorySyncMissingBooks",
        title = _("Library Sync: Sync missing books"),
        general = true,
    })
    Dispatcher:registerAction("grimmory_refresh_existing_metadata", {
        category = "none",
        event = "GrimmoryRefreshExistingMetadata",
        title = _("Library Sync: Refresh existing metadata"),
        general = true,
    })
    Dispatcher:registerAction("grimmory_refresh_open_book_metadata", {
        category = "none",
        event = "GrimmoryRefreshOpenBookMetadata",
        title = _("Library Sync: Refresh open book metadata"),
        general = true,
    })
end

function GrimmorySync:registerFileDialogButtons()
    local ok_filemanager, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok_filemanager or not FileManager or type(FileManager.addFileDialogButtons) ~= "function" then
        return
    end

    FileManager:addFileDialogButtons("grimmory_refresh_metadata", function(file, is_file)
        if not is_file or not self:isEpubPath(file) then
            return nil
        end

        return {
            {
                text = _("Refresh server metadata"),
                callback = function()
                    local file_chooser = FileManager.instance and FileManager.instance.file_chooser
                    if file_chooser and file_chooser.file_dialog then
                        UIManager:close(file_chooser.file_dialog)
                    end
                    self:startMetadataRefreshForFile(file)
                end,
            },
        }
    end)
end

function GrimmorySync:addToMainMenu(menu_items)
    menu_items.grimmory_sync = {
        text = _("Library Sync"),
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
                text = _("Refresh open book metadata"),
                enabled_func = function()
                    return self:currentDocumentPath() ~= nil
                end,
                callback = function(touchmenu_instance)
                    self:runAfterMenuClose(touchmenu_instance, function()
                        self:startMetadataRefreshForOpenBook()
                    end)
                end,
            },
            {
                text = _("Automatic metadata refresh"),
                sub_item_table_func = function()
                    return self:getAutomaticMetadataRefreshMenu()
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
                text = _("Download file naming"),
                sub_item_table_func = function()
                    return self:getFilenameProfileMenu()
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
                        self:showServerTypeConfig()
                    end)
                end,
            },
            {
                text = _("Select sync source"),
                sub_item_table_func = function()
                    return self:getShelfSelectionMenu()
                end,
            },
            {
                text = _("Mirror selected sync source"),
                checked_func = function()
                    return self.mirror_selected_sync_source == true
                end,
                callback = function(touchmenu_instance)
                    self:runAfterMenuClose(touchmenu_instance, function()
                        self:toggleMirrorSelectedSyncSource()
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

function GrimmorySync:toggleMirrorSelectedSyncSource()
    if self.mirror_selected_sync_source == true then
        self.mirror_selected_sync_source = false
        self:saveSettings()
        UIManager:show(InfoMessage:new{
            text = _("Mirror selected sync source disabled"),
            timeout = 2,
        })
        return
    end

    local sync_source = (self.selected_feed and self.selected_feed ~= "")
        and (self.selected_feed_label ~= "" and self.selected_feed_label or self.selected_feed)
        or _("All books")

    local confirm_dialog
    confirm_dialog = ConfirmBox:new{
        text = string.format(
            _("Mirror selected sync source?\n\nSource: %s\n\nWhen enabled, Sync missing books will also move manifest-tracked local EPUBs that are no longer in this source to %s. Other local files are left untouched, and the currently open book is skipped."),
            sync_source,
            MIRROR_TRASH_DIR
        ),
        ok_text = _("Enable"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            pcall(function() UIManager:close(confirm_dialog) end)
            self.mirror_selected_sync_source = true
            self:saveSettings()
            UIManager:show(InfoMessage:new{
                text = _("Mirror selected sync source enabled"),
                timeout = 3,
            })
        end,
    }
    UIManager:show(confirm_dialog)
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
                local message = self.sync_author_images
                    and _("Bookshelf author image sync enabled")
                    or _("Bookshelf author image sync disabled")
                if self.sync_author_images and self:provider().api_credentials_separate then
                    local api_username, api_password = self:apiCredentials()
                    if api_username == "" or api_password == "" then
                        message = string.format(
                            _("Bookshelf author image sync enabled. %s account credentials are required under Configure."),
                            self:serverName()
                        )
                    end
                end
                UIManager:show(InfoMessage:new{
                    text = message,
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

function GrimmorySync:getAutomaticMetadataRefreshMenu()
    return {
        {
            text = _("Check at startup"),
            checked_func = function()
                return self.auto_refresh_on_startup == true
            end,
            keep_menu_open = true,
            callback = function()
                self.auto_refresh_on_startup = not (self.auto_refresh_on_startup == true)
                self.auto_refresh_startup_pending = false
                self:saveSettings()
                self:configureAutomaticMetadataRefresh()
            end,
        },
        {
            text = _("Check interval"),
            sub_item_table_func = function()
                return self:getAutomaticMetadataRefreshIntervalMenu()
            end,
        },
        {
            text = _("Use OPDS updated timestamp as refresh trigger"),
            checked_func = function()
                return self.auto_refresh_use_opds_updated == true
            end,
            keep_menu_open = true,
            callback = function()
                self.auto_refresh_use_opds_updated = not (self.auto_refresh_use_opds_updated == true)
                self:saveSettings()
            end,
        },
        {
            text = _("Automatic checks scan the library and contact the server, which can use more battery. OPDS timestamps may refresh books after server-side changes that are not direct metadata edits."),
            enabled = false,
        },
    }
end

function GrimmorySync:getAutomaticMetadataRefreshIntervalMenu()
    local items = {}
    for _, interval in ipairs(AUTO_REFRESH_INTERVAL_LIST) do
        local hours = interval.hours
        table.insert(items, {
            text = interval.label,
            checked_func = function()
                return normalizeAutoRefreshInterval(self.auto_refresh_interval_hours) == hours
            end,
            keep_menu_open = true,
            callback = function()
                self.auto_refresh_interval_hours = hours
                self:saveSettings()
                self:configureAutomaticMetadataRefresh()
            end,
        })
    end
    return items
end

function GrimmorySync:routingProfileLabel(profile_id)
    for _, profile in ipairs(ROUTING_PROFILE_LIST) do
        if profile.id == profile_id then
            return profile.label
        end
    end
    return ROUTING_PROFILE_LIST[1].label
end

function GrimmorySync:filenameProfileLabel(profile_id)
    for _, profile in ipairs(FILENAME_PROFILE_LIST) do
        if profile.id == profile_id then
            return profile.label
        end
    end
    return FILENAME_PROFILE_LIST[1].label
end

function GrimmorySync:getRoutingProfileMenu()
    local items = {}
    for _, profile in ipairs(ROUTING_PROFILE_LIST) do
        local profile_id = profile.id
        table.insert(items, {
            text = profile.label,
            checked_func = function()
                return (self.routing_profile or ROUTING_PROFILE_FLAT) == profile_id
            end,
            keep_menu_open = true,
            callback = function()
                self.routing_profile = profile_id
                self:saveSettings()
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

function GrimmorySync:getFilenameProfileMenu()
    local items = {}
    for _, profile in ipairs(FILENAME_PROFILE_LIST) do
        local profile_id = profile.id
        table.insert(items, {
            text = profile.label,
            checked_func = function()
                return (self.filename_profile or FILENAME_PROFILE_SYNC_DEFAULT) == profile_id
            end,
            keep_menu_open = true,
            callback = function()
                self.filename_profile = profile_id
                self:saveSettings()
            end,
        })
    end

    return items
end

function GrimmorySync:showServerTypeConfig()
    local dialog
    local function selectServer(server_type)
        local changed = self.server_type ~= server_type
        self.server_type = server_type
        if changed then
            self.selected_feed = ""
            self.selected_feed_label = ""
        end
        UIManager:close(dialog)
        self:showServerConfig()
    end

    dialog = ButtonDialog:new{
        title = _("Library server"),
        buttons = {
            {
                {
                    text = "Grimmory",
                    callback = function()
                        selectServer(SERVER_GRIMMORY)
                    end,
                },
                {
                    text = "BookOrbit",
                    callback = function()
                        selectServer(SERVER_BOOKORBIT)
                    end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function GrimmorySync:showServerConfig()
    local input_dialog
    input_dialog = InputDialog:new{
        title = string.format(_("%s server URL"), self:serverName()),
        input = self.server_url,
        input_hint = "http://192.168.1.100:6060",
        input_type = "text",
        buttons = {
            {
                {
                    text = _("Back"),
                    callback = function()
                        UIManager:close(input_dialog)
                        self:showServerTypeConfig()
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
    local title = string.format(_("%s OPDS username (optional)"), self:serverName())
    if self.server_type == SERVER_GRIMMORY then
        title = _("Grimmory KOReader Sync username (optional)")
    elseif self.server_type == SERVER_BOOKORBIT then
        title = _("BookOrbit OPDS username (optional)")
    end
    local input_dialog
    input_dialog = InputDialog:new{
        title = title,
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
    local title = string.format(_("%s OPDS password (optional)"), self:serverName())
    if self.server_type == SERVER_GRIMMORY then
        title = _("Grimmory KOReader Sync password (optional)")
    elseif self.server_type == SERVER_BOOKORBIT then
        title = _("BookOrbit OPDS password (optional)")
    end
    local input_dialog
    input_dialog = InputDialog:new{
        title = title,
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
                        if self:provider().api_credentials_separate then
                            self:showApiUsernameConfig()
                        else
                            self:showPathConfig()
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function GrimmorySync:showApiUsernameConfig()
    local title = string.format(_("%s account username (optional)"), self:serverName())
    local description = _("Used only for extra metadata and Bookshelf author images. OPDS syncing works without it.")
    if self.server_type == SERVER_GRIMMORY then
        title = _("Grimmory account username (optional)")
        description = _("Use your normal Grimmory account credentials for extra metadata and Bookshelf author images. OPDS syncing uses the separate KOReader Sync credentials.")
    elseif self.server_type == SERVER_BOOKORBIT then
        title = _("BookOrbit account username (optional)")
    end
    local input_dialog
    input_dialog = InputDialog:new{
        title = title,
        input = self.api_username or "",
        input_type = "text",
        description = description,
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
                    text = _("Next"),
                    callback = function()
                        self.api_username = input_dialog:getInputText()
                        UIManager:close(input_dialog)
                        self:showApiPasswordConfig()
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

function GrimmorySync:showApiPasswordConfig()
    local title = string.format(_("%s account password (optional)"), self:serverName())
    if self.server_type == SERVER_GRIMMORY then
        title = _("Grimmory account password (optional)")
    elseif self.server_type == SERVER_BOOKORBIT then
        title = _("BookOrbit account password (optional)")
    end
    local input_dialog
    input_dialog = InputDialog:new{
        title = title,
        input = self.api_password or "",
        input_type = "text",
        text_type = "password",
        buttons = {
            {
                {
                    text = _("Back"),
                    callback = function()
                        UIManager:close(input_dialog)
                        self:showApiUsernameConfig()
                    end,
                },
                {
                    text = _("Next"),
                    callback = function()
                        self.api_password = input_dialog:getInputText()
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
                        if self:provider().api_credentials_separate then
                            self:showApiPasswordConfig()
                        else
                            self:showPasswordConfig()
                        end
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        self.local_path = input_dialog:getInputText()
                        self:saveSettings()
                        self:configureAutomaticMetadataRefresh()
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
                        if entry ~= MIRROR_TRASH_DIR then
                            scanDirectory(full_path, rel_path)
                        end
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

    local base = self:serverBaseUrl()
    endpoint = tostring(endpoint or "")
    if endpoint:sub(1, 1) ~= "/" then
        endpoint = "/" .. endpoint
    end
    return base .. endpoint
end

function GrimmorySync:serverBaseUrl()
    local base = trim(self.server_url):gsub("/+$", "")
    -- Accept the OPDS endpoint BookOrbit displays as well as the server origin.
    base = base:gsub("/api/v1/opds.*$", "")
    base = base:gsub("/api/v1$", "")
    return base
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

    local current_url = url
    local method = options.method or "GET"
    local body_text = options.body
    local redirects = 0
    local max_redirects = options.max_redirects or 5
    local can_follow_redirects = options.follow_redirects ~= false and not options.sink

    while true do
        local headers = {}
        for key, value in pairs(options.headers or {}) do
            headers[key] = value
        end

        local response_body
        local sink = options.sink
        if not sink then
            response_body = {}
            sink = ltn12.sink.table(response_body)
        end

        local request = {
            url = current_url,
            method = method,
            headers = headers,
            sink = sink,
        }

        if body_text then
            headers["content-length"] = tostring(#body_text)
            request.source = ltn12.source.string(body_text)
        end

        local request_func = current_url:match("^https://")
            and (ok_https and https.request or http.request)
            or http.request

        local success, status_code, response_headers = request_func(request)
        local status_num = tonumber(status_code)
        local body = response_body and table.concat(response_body) or true

        if not success then
            return body, string.format(_("Connection failed: %s"), tostring(status_code)), status_code, response_headers
        end

        if status_num and status_num >= 300 and status_num < 400 and can_follow_redirects then
            local location = responseHeader(response_headers, "location")
            local redirect_url = resolveRedirectUrl(current_url, location)
            if redirect_url then
                redirects = redirects + 1
                if redirects > max_redirects then
                    return body, _("Too many HTTP redirects"), status_code, response_headers
                end
                logger.info("[GrimmorySync] Following HTTP redirect:", tostring(status_code), current_url, "->", redirect_url)
                current_url = redirect_url
                if status_num == 303 then
                    method = "GET"
                    body_text = nil
                end
            else
                local message = string.format(_("HTTP %s"), tostring(status_code))
                if location and location ~= "" then
                    message = string.format(_("HTTP %s redirect to %s"), tostring(status_code), tostring(location))
                end
                return body, message, status_code, response_headers
            end
        elseif status_num and (status_num < 200 or status_num >= 300) then
            local message = string.format(_("HTTP %s"), tostring(status_code))
            local location = responseHeader(response_headers, "location")
            if status_num >= 300 and status_num < 400 and location and location ~= "" then
                message = string.format(_("HTTP %s redirect to %s"), tostring(status_code), tostring(location))
            end
            return body, message, status_code, response_headers
        else
            return body, nil, status_code, response_headers
        end
    end
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

function GrimmorySync:opdsLinks(entry)
    local links = {}
    if type(entry) ~= "string" then
        return links
    end

    for attrs in entry:gmatch("<link%s+([^>]*)>") do
        local href = xmlAttr(attrs, "href")
        if href and href ~= "" then
            links[#links + 1] = {
                href = href:gsub("&amp;", "&"),
                rel = xmlAttr(attrs, "rel") or "",
                type = xmlAttr(attrs, "type") or "",
                title = xmlAttr(attrs, "title") or "",
                attrs = attrs,
            }
        end
    end

    return links
end

function GrimmorySync:isOpdsAcquisitionLink(link)
    local rel = tostring(link and link.rel or ""):lower()
    return rel:match("acquisition") ~= nil
end

function GrimmorySync:isLikelyBookDownloadLink(link)
    if not self:isOpdsAcquisitionLink(link) then
        return false, "not acquisition"
    end

    local href = tostring(link.href or "")
    local href_lower = href:lower()
    local type_lower = tostring(link.type or ""):lower()

    if type_lower:match("image") or type_lower:match("atom") or type_lower:match("opds") then
        return false, type_lower ~= "" and type_lower or "navigation/media"
    end

    if type_lower:match("epub") or href_lower:match("%.epub") then
        return true, "epub"
    end

    if type_lower ~= "" and not type_lower:match("octet%-stream") then
        return false, "unsupported publication type: " .. type_lower
    end

    if href_lower:match("/download") or href_lower:match("[?&]fileid=") or href_lower:match("[?&]bookid=") then
        return true, "download-url"
    end

    if type_lower == "" then
        return true, "unknown-type"
    end

    return false, type_lower
end

function GrimmorySync:opdsAcquisitionLink(entry, title)
    local fallback
    local fallback_reason

    for _, link in ipairs(self:opdsLinks(entry)) do
        local ok_link, reason = self:isLikelyBookDownloadLink(link)
        if ok_link then
            if reason == "epub" then
                return link
            end
            fallback = fallback or link
            fallback_reason = fallback_reason or reason
        elseif self:isOpdsAcquisitionLink(link) then
            logger.info(
                "[GrimmorySync] Ignoring non-EPUB acquisition link:",
                title or "(untitled)",
                "type:",
                link.type or "",
                "href:",
                link.href or "",
                "reason:",
                reason or "unknown"
            )
        end
    end

    if fallback then
        logger.warn(
            "[GrimmorySync] Using acquisition link without EPUB MIME type:",
            title or "(untitled)",
            "type:",
            fallback.type or "",
            "href:",
            fallback.href or "",
            "reason:",
            fallback_reason or "fallback"
        )
    end

    return fallback
end

function GrimmorySync:bookIdFromOpds(entry, download_link)
    local id_value = type(entry) == "string" and entry:match("<id>%s*(.-)%s*</id>") or nil
    id_value = xmlText(id_value or "") or id_value

    local candidates = {
        id_value,
        download_link,
    }

    local patterns = {
        "urn:[^:]+:book:(%d+)",
        "/api/v1/books/(%d+)/download",
        "/api/v1/books/(%d+)",
        "/books/(%d+)/download",
        "/books/(%d+)",
        "/opds/(%d+)/download",
        "/opds/books/(%d+)",
        "[?&]bookId=(%d+)",
        "[?&]book_id=(%d+)",
        "[?&]fileId=(%d+)",
        "[?&]id=(%d+)",
    }

    for _, value in ipairs(candidates) do
        value = tostring(value or "")
        for _, pattern in ipairs(patterns) do
            local matched = value:match(pattern)
            if matched and matched ~= "" then
                return matched
            end
        end
    end

    return nil
end

function GrimmorySync:fileNameFromOpdsLink(link)
    if type(link) ~= "table" then
        return nil
    end

    local title = trim(tostring(link.title or ""))
    if title:lower():match("%.epub$") then
        return title
    end

    local href = tostring(link.href or "")
    local path = href:gsub("[?#].*$", "")
    local filename = path:match("([^/]+%.epub)$")
    if filename then
        return urlDecode(filename)
    end

    return nil
end

function GrimmorySync:syncSourcePrefix(kind)
    local labels = {
        magic = _("[Magic] "),
        library = _("[Library] "),
        collection = _("[Collection] "),
        smartscope = _("[SmartScope] "),
    }
    return labels[kind] or ""
end

function GrimmorySync:fetchSyncSources()
    local sources = self:provider().sync_sources or {}
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
                    shelves[#shelves + 1] = {
                        label = self:syncSourcePrefix(source.kind) .. title,
                        href = href,
                    }
                end
            end
        else
            last_err = err
        end
    end
    if not any_ok then
        return nil, last_err or _("Could not load sync sources")
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

    local shelves, err = self:fetchSyncSources()
    if not shelves then
        items[#items + 1] = {
            text = string.format(_("Could not load sync sources: %s"), tostring(err)),
            enabled = false,
        }
        return items
    end

    if #shelves == 0 then
        items[#items + 1] = {
            text = _("No sync sources found on server"),
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

function GrimmorySync:seriesFromOpdsEntry(entry)
    local series = xmlText(entry:match('<meta[^>]*property="belongs%-to%-collection"[^>]*id="series"[^>]*>([^<]+)</meta>'))
    local series_index = xmlText(entry:match('<meta[^>]*property="group%-position"[^>]*refines="#series"[^>]*>([^<]+)</meta>'))

    if not series then
        series = xmlDecode(entry:match('<meta[^>]*name="calibre:series"[^>]*content="([^"]+)"'))
    end
    if not series_index then
        series_index = xmlDecode(entry:match('<meta[^>]*name="calibre:series_index"[^>]*content="([^"]+)"'))
    end

    if not series then
        for _, link in ipairs(self:opdsLinks(entry)) do
            if tostring(link.rel or ""):match("sort/series") then
                local title = trim(link.title or "")
                if title ~= "" then
                    local name, index = title:match("^(.-)%s+#([%d%.]+)$")
                    series = trim(name or title)
                    series_index = series_index or index
                    break
                end
            end
        end
    end

    return series, series_index
end

function GrimmorySync:fetchBooklistFromServer()
    logger.info("[GrimmorySync] Fetching books from:", self.server_url)
    logger.info("[GrimmorySync] Username:", self.username)
    
    -- First, get the root OPDS catalog to find the "All Books" link
    local root_response, err = self:makeRequest(self:provider().opds_root)
    
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
            local title = xmlText(entry:match("<title[^>]*>(.-)</title>"))
            local author = xmlText(entry:match("<author>.-<name[^>]*>(.-)</name>.-</author>"))
            -- Try alternative author formats if first pattern doesn't match
            if not author then
                author = xmlText(entry:match("<author[^>]*>(.-)</author>"))
            end
            if not author then
                author = xmlText(entry:match('<dc:creator[^>]*>(.-)</dc:creator>'))
            end

            local description = xmlText(entry:match("<summary[^>]*>(.-)</summary>")
                or entry:match("<content[^>]*>(.-)</content>"))

            local acquisition_link = self:opdsAcquisitionLink(entry, title)
            local download_link = acquisition_link and acquisition_link.href or nil
            
            -- Extract genres/tags (category elements)
            local genres = {}
            for category in entry:gmatch('<category[^>]*term="([^"]+)"') do
                table.insert(genres, category)
            end
            
            local series, series_index = self:seriesFromOpdsEntry(entry)
            
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
            
            if title and download_link then
                local book_id = self:bookIdFromOpds(entry, download_link)
                local opds_file_name = self:fileNameFromOpdsLink(acquisition_link)
                if not book_id then
                    logger.warn("[GrimmorySync] Book ID missing from OPDS entry:", title, "download:", download_link)
                end
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
                    opds_file_name = opds_file_name,
                    download_url = download_link,
                })
            elseif title then
                local acquisition_count = 0
                for _, link in ipairs(self:opdsLinks(entry)) do
                    if self:isOpdsAcquisitionLink(link) then
                        acquisition_count = acquisition_count + 1
                    end
                end
                logger.warn(
                    "[GrimmorySync] Book without usable download link:",
                    title,
                    "acquisition_links:",
                    acquisition_count
                )
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

function GrimmorySync:routingProfileRequiresGenres()
    local profile = self.routing_profile or ROUTING_PROFILE_FLAT
    return profile == ROUTING_PROFILE_GENRE_SERIES
        or profile == ROUTING_PROFILE_SWEDISH_EXAMPLE
end

function GrimmorySync:remoteBooksHaveGenres(remote_books)
    for _, book in ipairs(remote_books or {}) do
        if #(book.genres or {}) > 0 then
            return true
        end
    end
    return false
end

function GrimmorySync:validateDownloadRoutingMetadata(remote_books, api_error)
    if not self:routingProfileRequiresGenres() or #(remote_books or {}) == 0 then
        return true, nil
    end

    if self:remoteBooksHaveGenres(remote_books) then
        return true, nil
    end

    local message = _("Folder profile needs genre metadata, but no genres were available from OPDS or the server API.")
    if api_error and tostring(api_error) ~= "" then
        message = message .. "\n\n" .. string.format(_("Extra server metadata error: %s"), tostring(api_error))
    end
    return false, message
end

function GrimmorySync:fileNameBase(filename)
    filename = trim(tostring(filename or ""))
    if filename == "" then return nil end
    filename = filename:gsub("\\", "/")
    return filename:match("([^/]+)$") or filename
end

function GrimmorySync:sanitizeFilename(filename)
    filename = self:fileNameBase(filename)
    if not filename or filename == "" then return nil end
    filename = filename:gsub('[:<>"|?*]', '')
    filename = filename:gsub("^%s+", ""):gsub("%s+$", "")
    return filename ~= "" and filename or nil
end

function GrimmorySync:sanitizeFilenamePart(value)
    if not value or value == "" then return nil end
    value = tostring(value):gsub('[:<>"|?*]', '')
    value = value:gsub("/", "-"):gsub("\\", "-")
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    return value ~= "" and value or nil
end

function GrimmorySync:withEpubExtension(filename)
    if not filename or filename == "" then return nil end
    if filename:match("%.[^%.]+$") then return filename end
    return filename .. ".epub"
end

function GrimmorySync:grimmorySourceFilename(book)
    book = book or {}
    return self:fileNameBase(book.grimmory_file_name or book.opds_file_name or book.source_file_name or book.file_name)
end

function GrimmorySync:grimmorySourceRelativePath(book)
    book = book or {}
    local filename = self:grimmorySourceFilename(book)
    if not filename then return nil end

    local subpath = trim(tostring(book.grimmory_file_sub_path or book.source_file_sub_path or ""))
    subpath = subpath:gsub("\\", "/"):gsub("^/+", ""):gsub("/+$", "")
    if subpath == "" then return filename end
    return subpath .. "/" .. filename
end

function GrimmorySync:syncDefaultFilename(book)
    book = book or {}
    local safe_title = self:sanitizeFilenamePart(book.title)
    if not safe_title then return nil end

    local safe_author = self:sanitizeFilenamePart(self:convertAuthorName(book.author))
    if safe_author then
        return string.format("%s - %s.epub", safe_author, safe_title)
    end
    return safe_title .. ".epub"
end

function GrimmorySync:calibreTitleAuthorsFilename(book)
    book = book or {}
    return self:calibreTitleAuthorsFilenameForTitle(book, book.title)
end

function GrimmorySync:calibreTitleAuthorsFilenameForTitle(book, title)
    book = book or {}
    local safe_title = self:sanitizeFilenamePart(title)
    if not safe_title then return nil end

    local safe_author = self:sanitizeFilenamePart(book.author)
    if safe_author then
        return string.format("%s - %s.epub", safe_title, safe_author)
    end
    return safe_title .. ".epub"
end

function GrimmorySync:articleSortedTitle(title)
    title = trim(tostring(title or ""))
    if title == "" then return nil end

    local lower = title:lower()
    local articles = {
        { prefix = "the ", article = "The" },
        { prefix = "an ", article = "An" },
        { prefix = "a ", article = "A" },
    }

    for _, entry in ipairs(articles) do
        if lower:sub(1, #entry.prefix) == entry.prefix then
            local rest = trim(title:sub(#entry.prefix + 1))
            if rest ~= "" then
                return rest .. ", " .. entry.article
            end
        end
    end

    return nil
end

function GrimmorySync:calibreArticleSortedTitleAuthorsFilename(book)
    local sorted_title = self:articleSortedTitle(book and book.title)
    if not sorted_title then return nil end
    return self:calibreTitleAuthorsFilenameForTitle(book, sorted_title)
end

function GrimmorySync:preferredDownloadFilename(book)
    local profile = self.filename_profile or FILENAME_PROFILE_SYNC_DEFAULT
    local filename

    if profile == FILENAME_PROFILE_GRIMMORY then
        filename = self:sanitizeFilename(self:grimmorySourceFilename(book))
        if not filename and self.server_type == SERVER_BOOKORBIT then
            -- BookOrbit's OPDS download name is Title - Author, not the source path.
            filename = self:calibreTitleAuthorsFilename(book)
        end
    elseif profile == FILENAME_PROFILE_CALIBRE_TITLE_AUTHORS then
        filename = self:calibreTitleAuthorsFilename(book)
    end

    filename = filename or self:syncDefaultFilename(book) or self:calibreTitleAuthorsFilename(book)
    return self:withEpubExtension(filename or "Untitled.epub")
end

function GrimmorySync:generatePossibleFilenames(book)
    local filenames = {}
    local seen = {}

    local function add(filename, sanitize)
        if not filename or filename == "" then return end
        filename = sanitize and self:sanitizeFilename(filename) or self:fileNameBase(filename)
        filename = self:withEpubExtension(filename)
        if filename and not seen[filename] then
            seen[filename] = true
            filenames[#filenames + 1] = filename
        end
    end

    local source_filename = self:grimmorySourceFilename(book)
    add(source_filename, false)
    add(source_filename, true)
    add(self:syncDefaultFilename(book), false)
    add(self:calibreTitleAuthorsFilename(book), false)
    add(self:calibreArticleSortedTitleAuthorsFilename(book), false)

    local safe_title = self:sanitizeFilenamePart(book and book.title)
    add(safe_title and (safe_title .. ".epub"), false)
    if safe_title and not self:sanitizeFilenamePart(book and book.author) then
        add(" - " .. safe_title .. ".epub", false)
    end

    return filenames
end

function GrimmorySync:generatePossibleRelativePaths(book)
    local paths = {}
    local seen = {}

    local function add(path)
        path = trim(tostring(path or ""))
        if path == "" then return end
        path = path:gsub("\\", "/"):gsub("^/+", "")
        if not seen[path] then
            seen[path] = true
            paths[#paths + 1] = path
        end
    end

    add(self:grimmorySourceRelativePath(book))
    return paths
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

function GrimmorySync:comparisonKeyVariants(str)
    local variants = {}
    local seen = {}

    local function add(value)
        local normalized = self:normalizeForComparison(value)
        if normalized ~= "" and not seen[normalized] then
            seen[normalized] = true
            variants[#variants + 1] = normalized
        end
    end

    add(str)
    if type(str) == "string" and str:match("_") then
        add(str:gsub("_", " "))
        add(str:gsub("_", ""))
    end

    return variants
end

function GrimmorySync:buildLocalBookIndex(local_books)
    local index = {
        lookup = {},
        path_lookup = {},
        files = {},
    }

    for _, book in ipairs(local_books) do
        -- Extract just the filename from the path (could be nested like "Author - Series/1 - Title.epub")
        local filename = book.filename:match("([^/]+)$") or book.filename
        local normalized = self:normalizeForComparison(filename)
        local normalized_path = self:normalizeForComparison((book.filename or ""):gsub("\\", "/"))
        for _, key in ipairs(self:comparisonKeyVariants(filename)) do
            index.lookup[key] = book
        end
        for _, key in ipairs(self:comparisonKeyVariants((book.filename or ""):gsub("\\", "/"))) do
            index.path_lookup[key] = book
        end
        table.insert(index.files, {
            normalized = normalized,
            normalized_path = normalized_path,
            book = book,
        })
        logger.info("[GrimmorySync] Local file:", normalized)
    end

    return index
end

function GrimmorySync:findLocalMatch(remote, local_index)
    local possible_names = self:generatePossibleFilenames(remote)
    local possible_paths = self:generatePossibleRelativePaths(remote)

    logger.info("[GrimmorySync] Checking remote book:", remote.title, "author:", remote.author or "none", "series:", remote.series or "none")
    for idx, ppath in ipairs(possible_paths) do
        logger.info("[GrimmorySync]   Possible path", idx, ":", ppath)
    end
    for idx, pname in ipairs(possible_names) do
        logger.info("[GrimmorySync]   Possible name", idx, ":", pname)
    end

    for _, path in ipairs(possible_paths) do
        for _, normalized_path in ipairs(self:comparisonKeyVariants(path)) do
            local exact_path_match = local_index.path_lookup[normalized_path]
            if exact_path_match then
                return exact_path_match, path, false
            end
        end
    end

    for _, name in ipairs(possible_names) do
        local normalized = self:normalizeForComparison(name)
        for _, normalized_name in ipairs(self:comparisonKeyVariants(name)) do
            local exact_match = local_index.lookup[normalized_name]
            if exact_match then
                return exact_match, name, false
            end
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
    parts[#parts + 1] = remote.hardcover_edition_id or ""
    parts[#parts + 1] = remote.description or ""
    parts[#parts + 1] = table.concat(genres, "|")

    return parts
end

function GrimmorySync:remoteMetadataSignature(remote)
    return table.concat(self:metadataSignatureParts(remote), SIGNATURE_SEPARATOR)
end

function GrimmorySync:remoteOpdsTimestamp(remote)
    return (remote and (remote.updated or remote.published)) or ""
end

function GrimmorySync:remoteBookKey(remote)
    if type(remote) ~= "table" then
        return nil
    end

    local book_id = trim(tostring(remote.book_id or ""))
    if book_id ~= "" then
        return "id:" .. book_id
    end

    local download_url = trim(tostring(remote.download_url or ""))
    if download_url ~= "" then
        return "url:" .. download_url
    end

    local title = trim(tostring(remote.title or ""))
    local author = trim(tostring(remote.author or ""))
    if title ~= "" or author ~= "" then
        return "meta:" .. self:normalizeForComparison(title .. "|" .. author)
    end

    return nil
end

function GrimmorySync:currentSyncScope()
    local scope = {
        server_type = Providers.isValid(self.server_type) and self.server_type or SERVER_GRIMMORY,
        server_url = self:serverBaseUrl(),
        sync_source = self.selected_feed or "",
        sync_source_label = self.selected_feed_label or "",
    }
    scope.key = table.concat({
        scope.server_type,
        scope.server_url,
        scope.sync_source,
    }, SIGNATURE_SEPARATOR)
    return scope
end

function GrimmorySync:manifestScopeFields(remote)
    local scope = self:currentSyncScope()
    return {
        server_type = scope.server_type,
        server_url = scope.server_url,
        sync_source = scope.sync_source,
        sync_source_label = scope.sync_source_label,
        sync_scope_key = scope.key,
        remote_key = self:remoteBookKey(remote),
    }
end

function GrimmorySync:manifestEntryMatchesScope(entry, scope)
    if type(entry) ~= "table" or type(scope) ~= "table" then
        return false
    end
    return entry.sync_scope_key == scope.key
        and entry.server_type == scope.server_type
        and entry.server_url == scope.server_url
        and (entry.sync_source or "") == scope.sync_source
end

function GrimmorySync:manifestOpdsTimestamp(manifest_entry)
    return (manifest_entry and (manifest_entry.updated or manifest_entry.published)) or ""
end

function GrimmorySync:opdsTimestampRefreshState(manifest_entry, remote)
    if self.auto_refresh_use_opds_updated ~= true then
        return false, false
    end

    local current_timestamp = self:remoteOpdsTimestamp(remote)
    if current_timestamp == "" then
        return false, false
    end

    local previous_timestamp = self:manifestOpdsTimestamp(manifest_entry)
    if previous_timestamp == "" then
        return false, true
    end

    return previous_timestamp ~= current_timestamp, false
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
        "",
        parts[5] or "",
        parts[6] or "",
    }, SIGNATURE_SEPARATOR)
end

function GrimmorySync:stableSignatureWithEditionFromPriorCurrent(signature)
    local parts = self:splitMetadataSignature(signature)
    if #parts ~= 8 then
        return nil
    end

    return table.concat({
        parts[1] or "",
        parts[2] or "",
        parts[3] or "",
        parts[4] or "",
        parts[5] or "",
        parts[6] or "",
        "",
        parts[7] or "",
        parts[8] or "",
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

    if self:stableSignatureWithEditionFromPriorCurrent(manifest_entry.signature) == current_signature then
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
    manifest_entry.hardcover_edition_id = remote.hardcover_edition_id
    manifest_entry.signature_migrated_at = os.time()
end

function GrimmorySync:updateManifestRemoteState(manifest_entry, remote)
    if not manifest_entry then return end
    manifest_entry.signature = self:remoteMetadataSignature(remote)
    manifest_entry.updated = remote.updated
    manifest_entry.published = remote.published
    manifest_entry.download_url = remote.download_url
    manifest_entry.title = remote.title
    manifest_entry.author = remote.author
    manifest_entry.hardcover_id = remote.hardcover_id
    manifest_entry.hardcover_book_id = remote.hardcover_book_id
    manifest_entry.hardcover_edition_id = remote.hardcover_edition_id
end

function GrimmorySync:getManifestEntry(manifest, path)
    local key = self:manifestKeyForPath(path)
    return manifest.books[key], key
end

function GrimmorySync:storeManifestEntry(manifest, path, remote)
    local key = self:manifestKeyForPath(path)
    local scope_fields = self:manifestScopeFields(remote)
    manifest.books[key] = {
        signature = self:remoteMetadataSignature(remote),
        updated = remote.updated,
        published = remote.published,
        download_url = remote.download_url,
        title = remote.title,
        author = remote.author,
        hardcover_id = remote.hardcover_id,
        hardcover_book_id = remote.hardcover_book_id,
        hardcover_edition_id = remote.hardcover_edition_id,
        server_type = scope_fields.server_type,
        server_url = scope_fields.server_url,
        sync_source = scope_fields.sync_source,
        sync_source_label = scope_fields.sync_source_label,
        sync_scope_key = scope_fields.sync_scope_key,
        remote_key = scope_fields.remote_key,
        refreshed_at = os.time(),
    }
end

function GrimmorySync:trackManifestEntryScope(manifest, path, remote)
    if not manifest or not path then
        return false
    end

    local key = self:manifestKeyForPath(path)
    local entry = manifest.books[key]
    if type(entry) ~= "table" then
        entry = {}
        manifest.books[key] = entry
    end

    local scope_fields = self:manifestScopeFields(remote)
    local changed = false
    local function setField(field, value)
        value = value or ""
        if entry[field] ~= value then
            entry[field] = value
            changed = true
        end
    end

    setField("server_type", scope_fields.server_type)
    setField("server_url", scope_fields.server_url)
    setField("sync_source", scope_fields.sync_source)
    setField("sync_source_label", scope_fields.sync_source_label)
    setField("sync_scope_key", scope_fields.sync_scope_key)
    setField("remote_key", scope_fields.remote_key)
    setField("title", remote and remote.title or entry.title)
    setField("author", remote and remote.author or entry.author)

    if changed then
        entry.tracked_at = os.time()
    end
    return changed
end

function GrimmorySync:normalizePathForCompare(path)
    if type(path) ~= "string" then
        return ""
    end
    return path:gsub("\\", "/"):gsub("/+", "/")
end

function GrimmorySync:isEpubPath(path)
    if type(path) ~= "string" then
        return false
    end
    return (path:match("%.([^%.]+)$") or ""):lower() == "epub"
end

function GrimmorySync:displayNameForPath(path)
    if type(path) ~= "string" or path == "" then
        return _("Unknown book")
    end
    return path:gsub("\\", "/"):match("([^/]+)$") or path
end

function GrimmorySync:relativeBookPath(path)
    local normalized_path = self:normalizePathForCompare(path)
    local normalized_root = self:normalizePathForCompare((self.local_path or ""):gsub("/+$", ""))
    if normalized_root ~= "" and normalized_path:sub(1, #normalized_root + 1) == normalized_root .. "/" then
        return normalized_path:sub(#normalized_root + 2)
    end
    return self:displayNameForPath(normalized_path)
end

function GrimmorySync:localBookFromPath(path)
    if type(path) ~= "string" or path == "" then
        return nil, _("No book file selected.")
    end
    if not self:isEpubPath(path) then
        return nil, _("Only EPUB files can be refreshed from the library server.")
    end

    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs then
        local attr = lfs.attributes(path)
        if not attr or attr.mode ~= "file" then
            return nil, _("Selected book file was not found.")
        end
    end

    return {
        path = path,
        filename = self:relativeBookPath(path),
    }, nil
end

function GrimmorySync:currentDocumentPath()
    if self.ui and self.ui.document and self.ui.document.file then
        return self.ui.document.file
    end

    local ok_reader, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok_reader and ReaderUI and ReaderUI.instance
        and ReaderUI.instance.document and ReaderUI.instance.document.file then
        return ReaderUI.instance.document.file
    end

    return nil
end

function GrimmorySync:isCurrentDocumentPath(path)
    local current_path = self:currentDocumentPath()
    if not current_path or not path then
        return false
    end
    return self:normalizePathForCompare(current_path) == self:normalizePathForCompare(path)
end

function GrimmorySync:refreshFileBrowserContent()
    local ok_event, Event = pcall(require, "ui/event")
    if ok_event and Event then
        UIManager:broadcastEvent(Event:new("RefreshContent"))
    end
end

function GrimmorySync:authorImagesPath()
    return (self.local_path or DEFAULT_LOCAL_PATH):gsub("/+$", "")
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
    elseif not self:provider().api_credentials_separate
        and self.username ~= "" and self.password ~= "" then
        local mime = require("mime")
        headers["authorization"] = "Basic " .. mime.b64(self.username .. ":" .. self.password)
    end
    return headers
end

function GrimmorySync:loginToServerApi()
    local candidates = self:apiCredentialCandidates()
    if #candidates == 0 then
        return nil, string.format(_("%s API sync requires an account username and password."), self:serverName())
    end

    local last_error
    for index, candidate in ipairs(candidates) do
        local body = jsonObject({
            username = candidate.username,
            password = candidate.password,
        })

        local response, err = self:httpRequest(self:buildServerUrl(self:provider().api_login), {
            method = "POST",
            body = body,
            headers = {
                ["accept"] = "application/json",
                ["content-type"] = "application/json",
            },
        })
        if err then
            last_error = err
            if index < #candidates then
                logger.warn("[GrimmorySync] Server API login failed with", candidate.label or "credentials", "credentials:", err)
            end
        else
            local data, decode_err = jsonDecode(response)
            if not data then
                local token = response and response:match('"accessToken"%s*:%s*"([^"]+)"')
                if token and token ~= "" then
                    return token, nil
                end
                last_error = decode_err
            elseif type(data.accessToken) == "string" and data.accessToken ~= "" then
                if index > 1 then
                    logger.info("[GrimmorySync] Server API login succeeded with fallback credentials:", candidate.label or "credentials")
                end
                return data.accessToken, nil
            else
                last_error = string.format(_("No access token returned by %s."), self:serverName())
            end
        end
    end

    return nil, last_error
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

function GrimmorySync:bookApiTitle(book)
    local metadata = self:bookApiMetadata(book)
    return self:metadataFieldValue(metadata.title or book.title)
end

function GrimmorySync:bookApiAuthor(book)
    local metadata = self:bookApiMetadata(book)
    local authors = metadata.authors or metadata.author or metadata.creator or book.authors or book.author
    if type(authors) == "table" then
        local parts = {}
        for _, author in ipairs(authors) do
            if type(author) == "table" then
                local name = self:metadataFieldValue(author.name or author.fullName or author.sortName)
                if name ~= "" then
                    parts[#parts + 1] = name
                end
            else
                local name = self:metadataFieldValue(author)
                if name ~= "" then
                    parts[#parts + 1] = name
                end
            end
        end
        return table.concat(parts, ", ")
    end
    return self:metadataFieldValue(authors)
end

function GrimmorySync:bookApiMatchKey(title, author)
    title = self:normalizeForComparison(title or "")
    author = self:normalizeForComparison(author or "")
    if title == "" then return nil end
    return title .. "|" .. author
end

function GrimmorySync:apiBookMatchKey(book)
    return self:bookApiMatchKey(self:bookApiTitle(book), self:bookApiAuthor(book))
end

function GrimmorySync:remoteBookMatchKey(remote)
    return self:bookApiMatchKey(remote and remote.title, remote and remote.author)
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

function GrimmorySync:fetchBookMetadataFromServerApi(token)
    logger.info("[GrimmorySync] Fetching book metadata from", self:serverName(), "API")
    local headers = self:apiAuthHeaders(token)
    headers["accept"] = "application/json"
    local api = self:provider().book_api

    if not api.paginated then
        local response, err = self:httpRequest(self:buildServerUrl(api.endpoint), {
            method = api.method or "GET",
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
            return nil, _("Could not find books array in server API response.")
        end
        return books, nil
    end

    headers["content-type"] = "application/json"
    local page = 0
    local page_size = api.page_size or 200
    local books = {}
    while true do
        local body = string.format(
            '{"sort":[{"field":"title","dir":"asc"}],"pagination":{"page":%d,"size":%d},"collapseSeries":false}',
            page,
            page_size
        )
        local response, err = self:httpRequest(self:buildServerUrl(api.endpoint), {
            method = api.method or "POST",
            body = body,
            headers = headers,
        })
        if err then
            return nil, err
        end

        local data, decode_err = jsonDecode(response)
        if not data then
            return nil, decode_err
        end
        local page_books = self:extractBooksArray(data)
        if not page_books then
            return nil, _("Could not find books array in server API response.")
        end
        for _, book in ipairs(page_books) do
            books[#books + 1] = book
        end

        local total = tonumber(data.total)
        if #page_books < page_size or (total and #books >= total) then
            break
        end
        page = page + 1
    end

    return books, nil
end

function GrimmorySync:apiStringList(value)
    local result = {}
    if type(value) ~= "table" then
        return result
    end
    for _, item in ipairs(value) do
        local text
        if type(item) == "table" then
            text = self:metadataFieldValue(item.name or item.title or item.value)
        else
            text = self:metadataFieldValue(item)
        end
        if text ~= "" then
            result[#result + 1] = text
        end
    end
    return result
end

function GrimmorySync:mergeBookCategories(remote, metadata)
    local seen = {}
    local merged = {}
    for _, value in ipairs(remote.genres or {}) do
        local key = tostring(value):lower()
        if not seen[key] then
            seen[key] = true
            merged[#merged + 1] = value
        end
    end
    for _, field in ipairs({ metadata.genres, metadata.tags }) do
        for _, value in ipairs(self:apiStringList(field)) do
            local key = value:lower()
            if not seen[key] then
                seen[key] = true
                merged[#merged + 1] = value
            end
        end
    end
    remote.genres = merged
end

function GrimmorySync:applyBookApiMetadata(remote_books, api_books)
    local by_id = {}
    local by_match_key = {}
    local by_title_key = {}
    local title_counts = {}

    for _, book in ipairs(api_books or {}) do
        local id = self:bookApiId(book)
        if id ~= nil then
            by_id[tostring(id)] = book
        end

        local match_key = self:apiBookMatchKey(book)
        if match_key then
            by_match_key[match_key] = by_match_key[match_key] or book
        end

        local title_key = self:normalizeForComparison(self:bookApiTitle(book))
        if title_key ~= "" then
            title_counts[title_key] = (title_counts[title_key] or 0) + 1
            by_title_key[title_key] = book
        end
    end

    local updated = 0
    local matched_by_id = 0
    local matched_by_key = 0
    local matched_by_title = 0
    for _, remote in ipairs(remote_books or {}) do
        local api_book = remote.book_id and by_id[tostring(remote.book_id)]
        local match_source = api_book and "id" or nil
        if not api_book then
            local match_key = self:remoteBookMatchKey(remote)
            api_book = match_key and by_match_key[match_key] or nil
            match_source = api_book and "title-author" or nil
        end
        if not api_book then
            local title_key = self:normalizeForComparison(remote and remote.title or "")
            if title_key ~= "" and title_counts[title_key] == 1 then
                api_book = by_title_key[title_key]
                match_source = api_book and "unique-title" or nil
            end
        end
        if api_book then
            local metadata = self:bookApiMetadata(api_book)
            local primary_file = type(api_book.primaryFile) == "table" and api_book.primaryFile or nil
            local hardcover_id = self:metadataFieldValue(metadata.hardcoverId)
            local hardcover_book_id = self:metadataFieldValue(metadata.hardcoverBookId)
            local hardcover_edition_id = self:metadataFieldValue(metadata.hardcoverEditionId)
            if hardcover_id ~= "" then remote.hardcover_id = hardcover_id end
            if hardcover_book_id ~= "" then remote.hardcover_book_id = hardcover_book_id end
            if hardcover_edition_id ~= "" then remote.hardcover_edition_id = hardcover_edition_id end
            local series = self:metadataFieldValue(metadata.seriesName or metadata.series)
            local series_index = self:metadataFieldValue(metadata.seriesIndex)
            if series ~= "" then remote.series = series end
            if series_index ~= "" then remote.series_index = series_index end
            self:mergeBookCategories(remote, metadata)
            if primary_file then
                remote.grimmory_file_name = self:metadataFieldValue(primary_file.fileName)
                remote.grimmory_file_sub_path = self:metadataFieldValue(primary_file.fileSubPath)
            end
            updated = updated + 1
            if match_source == "id" then
                matched_by_id = matched_by_id + 1
            elseif match_source == "title-author" then
                matched_by_key = matched_by_key + 1
            elseif match_source == "unique-title" then
                matched_by_title = matched_by_title + 1
            end
        end
    end

    logger.info(
        "[GrimmorySync] Enriched",
        updated,
        "books with server API metadata",
        "(id:",
        matched_by_id,
        "title-author:",
        matched_by_key,
        "unique-title:",
        matched_by_title,
        "remote:",
        #(remote_books or {}),
        "api:",
        #(api_books or {}),
        ")"
    )
    return updated
end

function GrimmorySync:enrichRemoteBooksWithBookApiMetadata(remote_books)
    local token, login_err = self:loginToServerApi()
    if not token then
        logger.warn("[GrimmorySync] Book metadata API enrichment skipped:", login_err)
        return false, login_err
    end

    local api_books, err = self:fetchBookMetadataFromServerApi(token)
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

function GrimmorySync:fetchAuthorsFromServer(token)
    logger.info("[GrimmorySync] Fetching", self:serverName(), "authors for Bookshelf images")
    local headers = self:apiAuthHeaders(token)
    headers["accept"] = "application/json"
    local api = self:provider().author_api
    local page = 0
    local page_size = api.page_size or 100
    local authors = {}

    while true do
        local endpoint = api.endpoint
        if api.paginated then
            local separator = endpoint:find("?", 1, true) and "&" or "?"
            endpoint = endpoint .. separator .. "page=" .. tostring(page) .. "&size=" .. tostring(page_size)
        end
        local response, err = self:httpRequest(self:buildServerUrl(endpoint), {
            headers = headers,
        })
        if err then
            return nil, err
        end

        local data, decode_err = jsonDecode(response)
        if not data then
            local fallback_authors = parseAuthorsFallback(response)
            if #fallback_authors > 0 and not api.paginated then
                logger.info("[GrimmorySync] Parsed authors with fallback JSON parser:", #fallback_authors)
                return fallback_authors, nil
            end
            return nil, decode_err
        end

        local page_authors = self:extractAuthorsArray(data)
        if not page_authors then
            return nil, _("Could not find authors array in server response.")
        end
        for _, author in ipairs(page_authors) do
            authors[#authors + 1] = author
        end

        local total = tonumber(data.total)
        if not api.paginated or #page_authors < page_size or (total and #authors >= total) then
            break
        end
        page = page + 1
    end

    logger.info("[GrimmorySync] Authors returned by", self:serverName() .. ":", #authors)
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

    local tmp_path = image_dir .. "/.library-sync-author-" .. tostring(id) .. ".tmp"
    pcall(os.remove, tmp_path)

    local file = io.open(tmp_path, "wb")
    if not file then
        return false, _("Could not create temporary author image file.")
    end

    local provider = self:provider()
    local image_url = provider.author_image_path(id)
    if provider.author_image_token_query and type(token) == "string" and token ~= "" then
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
        local token, err = self:loginToServerApi()
        if not token and not self:provider().api_credentials_separate then
            logger.warn("[GrimmorySync] Token login for author images failed; trying Basic auth:", err)
        elseif not token then
            return nil, err
        end

        if self.abort_sync then
            return nil, ABORTED
        end

        self:showProgressDialog(string.format(_("Fetching authors from %s..."), self:serverName()))
        local authors, authors_err = self:fetchAuthorsFromServer(token)
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

function GrimmorySync:apiMetadataWarning(error)
    if error == nil or tostring(error) == "" then
        return ""
    end
    local api_username, api_password = self:apiCredentials()
    if api_username == "" and api_password == "" then
        return ""
    end
    return "\n\n" .. string.format(_("Extra server metadata skipped: %s"), tostring(error))
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

    if (result.skipped_open or 0) > 0 then
        message = message .. string.format(
            _("\nSkipped currently open: %d books"),
            result.skipped_open or 0
        )
    end

    message = message .. self:apiMetadataWarning(stats.api_error)

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

function GrimmorySync:mirrorTrashPath()
    return (self.local_path or DEFAULT_LOCAL_PATH):gsub("/+$", "") .. "/" .. MIRROR_TRASH_DIR
end

function GrimmorySync:isPathInsideLocalLibrary(path)
    local normalized_path = self:normalizePathForCompare(path)
    local normalized_root = self:normalizePathForCompare((self.local_path or ""):gsub("/+$", ""))
    return normalized_root ~= ""
        and normalized_path:sub(1, #normalized_root + 1) == normalized_root .. "/"
end

function GrimmorySync:isMirrorTrashPath(path)
    local relative = self:relativeBookPath(path)
    return relative == MIRROR_TRASH_DIR
        or relative:sub(1, #MIRROR_TRASH_DIR + 1) == MIRROR_TRASH_DIR .. "/"
end

function GrimmorySync:remoteBookKeySet(remote_books)
    local keys = {}
    for _, remote in ipairs(remote_books or {}) do
        local key = self:remoteBookKey(remote)
        if key and key ~= "" then
            keys[key] = true
        end
    end
    return keys
end

function GrimmorySync:buildMirrorCleanupQueue(local_books, remote_books, manifest)
    local queue = {}
    local stats = {
        skipped_open = 0,
        skipped_missing = 0,
        skipped_untracked = 0,
        skipped_outside = 0,
    }

    if self.mirror_selected_sync_source ~= true then
        return queue, stats
    end

    manifest = manifest or self:loadManifest()
    local scope = self:currentSyncScope()
    local remote_keys = self:remoteBookKeySet(remote_books)

    local local_paths = {}
    for _, book in ipairs(local_books or {}) do
        if book.path then
            local_paths[self:normalizePathForCompare(book.path)] = true
        end
    end

    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    for key, entry in pairs(manifest.books or {}) do
        local remote_key = type(entry) == "table" and entry.remote_key or nil
        if remote_key and remote_key ~= "" and self:manifestEntryMatchesScope(entry, scope) then
            local path = key
            local normalized_path = self:normalizePathForCompare(path)
            if remote_keys[remote_key] then
                -- Still present in the selected sync source.
            elseif not self:isPathInsideLocalLibrary(path) or self:isMirrorTrashPath(path) or not self:isEpubPath(path) then
                stats.skipped_outside = stats.skipped_outside + 1
            elseif self:isCurrentDocumentPath(path) then
                stats.skipped_open = stats.skipped_open + 1
            elseif not local_paths[normalized_path] then
                stats.skipped_missing = stats.skipped_missing + 1
            else
                local attr = ok_lfs and lfs and lfs.attributes(path) or nil
                if attr and attr.mode == "file" then
                    queue[#queue + 1] = {
                        key = key,
                        path = path,
                        title = entry.title or self:displayNameForPath(path),
                        remote_key = remote_key,
                    }
                    logger.info("[GrimmorySync] Mirror cleanup candidate:", path)
                else
                    stats.skipped_missing = stats.skipped_missing + 1
                end
            end
        elseif self:manifestEntryMatchesScope(entry, scope) then
            stats.skipped_untracked = stats.skipped_untracked + 1
        end
    end

    return queue, stats
end

function GrimmorySync:uniquePath(path)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs or not lfs or not lfs.attributes(path) then
        return path
    end

    local base, ext = path:match("^(.*)(%.[^/%.]+)$")
    if not base then
        base, ext = path, ""
    end

    local i = 1
    local candidate = base .. " (" .. tostring(i) .. ")" .. ext
    while lfs.attributes(candidate) do
        i = i + 1
        candidate = base .. " (" .. tostring(i) .. ")" .. ext
    end
    return candidate
end

function GrimmorySync:moveBookToMirrorTrash(path)
    if not self:isPathInsideLocalLibrary(path) or self:isMirrorTrashPath(path) then
        return false, _("Refusing to move a file outside the configured library path.")
    end

    local relative = self:relativeBookPath(path)
    local trash_batch = self:mirrorTrashPath() .. "/" .. os.date("%Y%m%d-%H%M%S")
    local destination = self:uniquePath(trash_batch .. "/" .. relative)
    local destination_dir = destination:match("(.+)/[^/]+$") or trash_batch
    if not self:ensureDirectory(destination_dir) then
        return false, _("Could not create mirror trash directory.")
    end

    local ok, err = os.rename(path, destination)
    if not ok then
        return false, err or _("Could not move file to mirror trash.")
    end
    return true, destination
end

function GrimmorySync:moveMirrorCleanupAsync(queue, manifest, done_callback)
    local total = #queue
    local i = 0
    local moved = 0
    local failed = 0
    local skipped_open = 0
    local last_error
    manifest = manifest or self:loadManifest()

    if total == 0 then
        done_callback(true, {
            moved = 0,
            failed = 0,
            skipped_open = 0,
            remaining = 0,
            trash_path = self:mirrorTrashPath(),
        })
        return
    end

    local function finish(success, result)
        self:saveManifest(manifest)
        done_callback(success, result)
    end

    local function step()
        if self.abort_sync then
            finish(false, {
                error = ABORTED,
                moved = moved,
                failed = failed,
                skipped_open = skipped_open,
                remaining = total - i,
                trash_path = self:mirrorTrashPath(),
                last_error = last_error,
            })
            return
        end

        i = i + 1
        if i > total then
            finish(true, {
                moved = moved,
                failed = failed,
                skipped_open = skipped_open,
                remaining = 0,
                trash_path = self:mirrorTrashPath(),
                last_error = last_error,
            })
            return
        end

        local item = queue[i]
        self:showProgressDialog(string.format(
            _("Mirroring source %d of %d...\n\n%s\n\nMoved to trash: %d\n\nTap Cancel to stop after the current file."),
            i,
            total,
            self:displayNameForPath(item.path),
            moved
        ))

        UIManager:scheduleIn(PROGRESS_STEP_DELAY_S, function()
            if self:isCurrentDocumentPath(item.path) then
                skipped_open = skipped_open + 1
            else
                local ok, destination_or_err = self:moveBookToMirrorTrash(item.path)
                if ok then
                    moved = moved + 1
                    manifest.books[item.key] = nil
                    logger.info("[GrimmorySync] Moved removed source book to mirror trash:", item.path, "->", destination_or_err)
                else
                    failed = failed + 1
                    last_error = destination_or_err
                    logger.warn("[GrimmorySync] Mirror cleanup failed:", item.path, destination_or_err or "unknown")
                end
            end
            self:saveManifest(manifest)
            UIManager:scheduleIn(PROGRESS_STEP_DELAY_S, step)
        end)
    end

    UIManager:scheduleIn(PROGRESS_STEP_DELAY_S, step)
end

function GrimmorySync:buildMissingBookQueue(local_books, remote_books)
    local local_index = self:buildLocalBookIndex(local_books)
    local manifest = self:loadManifest()
    local missing = {}
    local manifest_changed = false

    for _, remote in ipairs(remote_books) do
        local matched_book, matched_name, fuzzy = self:findLocalMatch(remote, local_index)

        if matched_book then
            if self.mirror_selected_sync_source == true
                and self:trackManifestEntryScope(manifest, matched_book.path, remote) then
                manifest_changed = true
            end
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

    if manifest_changed then
        self:saveManifest(manifest)
    end

    return missing, manifest
end

function GrimmorySync:compareAndDownload(local_books, remote_books)
    local missing, manifest = self:buildMissingBookQueue(local_books, remote_books)
    local manifest_changed = false
    
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

function GrimmorySync:downloadMissingBooksAsync(missing, manifest, done_callback)
    local total = #missing
    local count = 0
    local i = 0
    manifest = manifest or self:loadManifest()

    if total == 0 then
        done_callback(true, { downloaded = 0, remaining = 0 })
        return
    end

    local function finish(success, result)
        self:saveManifest(manifest)
        done_callback(success, result)
    end

    local function step()
        if self.abort_sync then
            logger.info("[GrimmorySync] Sync aborted by user")
            finish(false, {
                error = ABORTED,
                downloaded = count,
                remaining = total - count,
            })
            return
        end

        i = i + 1
        if i > total then
            finish(true, {
                downloaded = count,
                remaining = 0,
            })
            return
        end

        local book = missing[i]
        self:showProgressDialog(string.format(
            _("Downloading book %d of %d...\n\n%s\n\nDownloaded: %d\n\nTap Cancel to stop after the current file."),
            i,
            total,
            book.title,
            count
        ))

        if UIManager.forceRePaint then
            pcall(function() UIManager:forceRePaint() end)
        end

        UIManager:scheduleIn(PROGRESS_STEP_DELAY_S, function()
            if self.abort_sync then
                UIManager:scheduleIn(0, step)
                return
            end

            local downloaded, path = self:downloadBook(book)
            if downloaded then
                count = count + 1
                if path then
                    self:storeManifestEntry(manifest, path, book)
                    self:saveManifest(manifest)
                end
            end

            UIManager:scheduleIn(PROGRESS_STEP_DELAY_S, step)
        end)
    end

    UIManager:scheduleIn(PROGRESS_STEP_DELAY_S, step)
end

function GrimmorySync:buildMetadataRefreshQueue(local_books, remote_books, options)
    options = options or {}
    local local_index = self:buildLocalBookIndex(local_books)
    local manifest = self:loadManifest()
    local matched = {}
    local skipped = 0
    local manifest_changed = false
    local queue_stats = {
        skipped_open = 0,
        metadata_changed = 0,
        opds_timestamp_changed = 0,
    }

    for _, remote in ipairs(remote_books) do
        local matched_book, matched_name, fuzzy = self:findLocalMatch(remote, local_index)
        if matched_book and matched_book.path then
            if options.skip_open_book and self:isCurrentDocumentPath(matched_book.path) then
                skipped = skipped + 1
                queue_stats.skipped_open = queue_stats.skipped_open + 1
                logger.info("[GrimmorySync] Skipping currently open book:", remote.title)
            else
                local manifest_entry = self:getManifestEntry(manifest, matched_book.path)
                local signature_matches, should_migrate = self:metadataSignatureMatches(manifest_entry, remote)
                local timestamp_changed, should_store_timestamp = self:opdsTimestampRefreshState(manifest_entry, remote)

                if signature_matches and not timestamp_changed then
                    skipped = skipped + 1
                    if should_migrate then
                        self:migrateManifestSignature(manifest_entry, remote)
                        manifest_changed = true
                        logger.info("[GrimmorySync] Migrated stable metadata signature:", remote.title)
                    elseif should_store_timestamp then
                        self:updateManifestRemoteState(manifest_entry, remote)
                        manifest_changed = true
                        logger.info("[GrimmorySync] Stored OPDS timestamp baseline:", remote.title)
                    end
                    logger.info("[GrimmorySync] Metadata unchanged, skipping:", remote.title)
                else
                    local reason = (signature_matches and timestamp_changed) and "opds_timestamp" or "metadata"
                    if reason == "opds_timestamp" then
                        queue_stats.opds_timestamp_changed = queue_stats.opds_timestamp_changed + 1
                        logger.info("[GrimmorySync] Will refresh:", remote.title, "(OPDS timestamp changed)")
                    else
                        queue_stats.metadata_changed = queue_stats.metadata_changed + 1
                        if fuzzy then
                            logger.info("[GrimmorySync] Will refresh:", remote.title, "(fuzzy matched:", matched_name, ")")
                        else
                            logger.info("[GrimmorySync] Will refresh:", remote.title, "(matched:", matched_name, ")")
                        end
                    end
                    table.insert(matched, {
                        remote = remote,
                        local_path = matched_book.path,
                        reason = reason,
                    })
                end
            end
        end
    end

    if manifest_changed then
        self:saveManifest(manifest)
    end

    return matched, skipped, manifest, queue_stats
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

function GrimmorySync:refreshExistingMetadataAsync(matched, skipped, manifest, done_callback, options)
    options = options or {}
    local total = #matched
    local count = 0
    local i = 0
    local skipped_open = 0
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
                skipped_open = skipped_open,
                remaining = total - count,
            })
            return
        end

        i = i + 1
        if i > total then
            finish(true, {
                refreshed = count,
                skipped = skipped or 0,
                skipped_open = skipped_open,
                remaining = 0,
            })
            return
        end

        local item = matched[i]
        if options.skip_open_book and self:isCurrentDocumentPath(item.local_path) then
            skipped_open = skipped_open + 1
            logger.info("[GrimmorySync] Skipping currently open book during refresh:", item.remote.title)
            UIManager:scheduleIn(options.silent and 0.1 or PROGRESS_STEP_DELAY_S, step)
            return
        end

        if not options.silent then
            self:showProgressDialog(string.format(
                _("Refreshing metadata %d of %d...\n\n%s\n\nUpdated: %d\nSkipped unchanged: %d\n\nTap Cancel to stop after the current file."),
                i,
                total,
                item.remote.title,
                count,
                skipped or 0
            ))
        end

        UIManager:scheduleIn(options.silent and 0.1 or PROGRESS_STEP_DELAY_S, function()
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

            UIManager:scheduleIn(options.silent and 0.1 or PROGRESS_STEP_DELAY_S, step)
        end)
    end

    UIManager:scheduleIn(options.silent and 0.1 or PROGRESS_STEP_DELAY_S, step)
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

        local filename_only = self:preferredDownloadFilename(book)

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

function GrimmorySync:networkAvailableForAutomaticRefresh()
    local ok_network, NetworkManager = pcall(require, "ui/network/manager")
    if not ok_network or not NetworkManager or not NetworkManager.isConnected then
        return true
    end

    local ok_connected, connected = pcall(function()
        return NetworkManager:isConnected()
    end)
    if not ok_connected then
        return true
    end
    return connected == true
end

function GrimmorySync:finishAutomaticMetadataRefresh(success, result)
    result = result or {}
    self.auto_refresh_running = false
    self.auto_refresh_startup_pending = false
    self.auto_refresh_last_check = os.time()
    self:saveSettings()

    if success then
        logger.info("[GrimmorySync] Automatic metadata refresh complete:", result.refreshed or 0, "updated")
        if (result.refreshed or 0) > 0 then
            local text = string.format(
                _("Automatic metadata refresh updated %d books."),
                result.refreshed or 0
            )
            if (result.skipped_open or 0) > 0 then
                text = text .. "\n" .. string.format(
                    _("Skipped currently open: %d books"),
                    result.skipped_open or 0
                )
            end
            UIManager:show(InfoMessage:new{
                text = text,
                timeout = 4,
            })
        end
    elseif result.error and result.error ~= "network_unavailable" and result.error ~= "busy" then
        logger.warn("[GrimmorySync] Automatic metadata refresh failed:", result.error)
        UIManager:show(InfoMessage:new{
            text = string.format(_("Automatic metadata refresh failed: %s"), tostring(result.error)),
            timeout = 5,
        })
    else
        logger.info("[GrimmorySync] Automatic metadata refresh skipped:", result.error or "not due")
    end

    self:configureAutomaticMetadataRefresh()
end

function GrimmorySync:performAutomaticMetadataRefresh(reason)
    if self.auto_refresh_running or self.sync_running then
        logger.info("[GrimmorySync] Automatic metadata refresh skipped because sync is already running")
        self:finishAutomaticMetadataRefresh(false, { error = "busy" })
        return
    end

    if not self:configurationReady() then
        self:finishAutomaticMetadataRefresh(false, { error = "server_not_configured" })
        return
    end

    if not self:networkAvailableForAutomaticRefresh() then
        self:finishAutomaticMetadataRefresh(false, { error = "network_unavailable" })
        return
    end

    self.auto_refresh_running = true
    self.abort_sync = false
    self.abort_notified = false
    logger.info("[GrimmorySync] Starting automatic metadata refresh:", reason or "timer")

    local ok, success, payload = pcall(function()
        local local_books = self:scanLocalBooks()
        logger.info("[GrimmorySync] Automatic refresh local books:", #local_books)

        local remote_books, err = self:fetchBooklistFromServer()
        if not remote_books then
            return false, err
        end

        logger.info("[GrimmorySync] Automatic refresh remote books:", #remote_books)

        local enriched, enrich_result = self:enrichRemoteBooksWithBookApiMetadata(remote_books)
        if enriched then
            logger.info("[GrimmorySync] Automatic refresh API metadata applied:", enrich_result)
        else
            logger.warn("[GrimmorySync] Automatic refresh continuing without Book API metadata:", enrich_result)
        end

        local matched, skipped, manifest, queue_stats = self:buildMetadataRefreshQueue(local_books, remote_books, {
            skip_open_book = true,
        })

        return true, {
            matched = matched,
            manifest = manifest,
            queue_stats = queue_stats,
            skipped = skipped or 0,
            local_count = #local_books,
            remote_count = #remote_books,
        }
    end)

    if not ok then
        self:finishAutomaticMetadataRefresh(false, { error = success })
        return
    end

    if not success then
        self:finishAutomaticMetadataRefresh(false, { error = payload })
        return
    end

    local stats = payload or {}
    local matched = stats.matched or {}
    local queue_stats = stats.queue_stats or {}

    if #matched == 0 then
        self:finishAutomaticMetadataRefresh(true, {
            refreshed = 0,
            skipped = stats.skipped or 0,
            skipped_open = queue_stats.skipped_open or 0,
        })
        return
    end

    self:refreshExistingMetadataAsync(matched, stats.skipped or 0, stats.manifest, function(done_ok, result)
        result = result or {}
        result.skipped_open = (result.skipped_open or 0) + (queue_stats.skipped_open or 0)
        if not done_ok then
            self:finishAutomaticMetadataRefresh(false, {
                error = result.error or _("unknown error"),
                refreshed = result.refreshed or 0,
                skipped = result.skipped or 0,
                skipped_open = result.skipped_open or 0,
            })
            return
        end

        self:finishAutomaticMetadataRefresh(true, result)
    end, {
        silent = true,
        skip_open_book = true,
    })
end

-- Named entry point for SimpleUI's QuickAction scanner.
-- Tapping the QuickAction tile opens the normal sync confirmation.
function GrimmorySync:show()
    self:onGrimmorySyncMissingBooks()
end

function GrimmorySync:onGrimmorySyncMissingBooks()
    self:runAfterMenuClose(function()
        self:startSync()
    end)
end

function GrimmorySync:onGrimmoryRefreshExistingMetadata()
    self:runAfterMenuClose(function()
        self:startMetadataRefresh()
    end)
end

function GrimmorySync:onGrimmoryRefreshOpenBookMetadata()
    self:runAfterMenuClose(function()
        self:startMetadataRefreshForOpenBook()
    end)
end

function GrimmorySync:startSync()
    if not self:configurationReady() then
        self:promptConfiguration()
        return
    end
    
    -- Reset abort flag
    self.abort_sync = false
    self.abort_notified = false
    
    -- Show confirmation with cancel option
    local confirm_text = _("Sync missing books?\n\nOnly books missing from this device will be downloaded. You can cancel at any time.")
    if self.mirror_selected_sync_source == true then
        confirm_text = _("Sync and mirror selected source?\n\nMissing books will be downloaded. Manifest-tracked local EPUBs that are no longer in the selected sync source will be moved to the local mirror trash. Other local files are left untouched. You can cancel at any time.")
    end
    local confirm_dialog
    confirm_dialog = ConfirmBox:new{
        text = confirm_text,
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

function GrimmorySync:startMetadataRefreshForOpenBook()
    local file_path = self:currentDocumentPath()
    if not file_path then
        UIManager:show(InfoMessage:new{
            text = _("No book is currently open."),
            timeout = 3,
        })
        return
    end

    self:startMetadataRefreshForFile(file_path, { offer_close_open_book = true })
end

function GrimmorySync:closeOpenBookAndRefresh(file_path)
    if not (self.ui and self.ui.document and type(self.ui.onClose) == "function") then
        UIManager:show(InfoMessage:new{
            text = _("Close this book before refreshing its metadata."),
            timeout = 4,
        })
        return
    end

    local close_message = InfoMessage:new{
        text = _("Closing book..."),
        timeout = 0,
    }
    UIManager:show(close_message)
    if UIManager.forceRePaint then
        UIManager:forceRePaint()
    end

    UIManager:nextTick(function()
        self.ui:onClose(false)
        if self.ui and type(self.ui.showFileManager) == "function" then
            self.ui:showFileManager(file_path)
        end
        UIManager:close(close_message)
        UIManager:scheduleIn(0.5, function()
            self:performMetadataRefreshForFile(file_path)
        end)
    end)
end

function GrimmorySync:startMetadataRefreshForFile(file_path, options)
    options = options or {}

    if not self:configurationReady() then
        self:promptConfiguration()
        return
    end

    local local_book, target_err = self:localBookFromPath(file_path)
    if not local_book then
        UIManager:show(InfoMessage:new{
            text = target_err or _("This file cannot be refreshed."),
            timeout = 4,
        })
        return
    end

    if self:isCurrentDocumentPath(file_path) then
        if not options.offer_close_open_book then
            UIManager:show(InfoMessage:new{
                text = _("Close this book before refreshing its metadata."),
                timeout = 4,
            })
            return
        end

        local close_dialog
        close_dialog = ConfirmBox:new{
            text = string.format(
                _("Refresh metadata for the open book?\n\n%s\n\nKOReader must close the book before Library Sync can replace the EPUB safely."),
                self:displayNameForPath(file_path)
            ),
            ok_text = _("Close and refresh"),
            cancel_text = _("Cancel"),
            ok_callback = function()
                pcall(function() UIManager:close(close_dialog) end)
                self:closeOpenBookAndRefresh(file_path)
            end,
        }
        UIManager:show(close_dialog)
        return
    end

    local confirm_dialog
    confirm_dialog = ConfirmBox:new{
        text = string.format(
            _("Refresh metadata for this book?\n\n%s\n\nOnly this local EPUB will be matched and replaced if server metadata has changed."),
            self:displayNameForPath(file_path)
        ),
        ok_text = _("Refresh"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            pcall(function() UIManager:close(confirm_dialog) end)
            UIManager:scheduleIn(0, function()
                self:performMetadataRefreshForFile(file_path)
            end)
        end,
    }
    UIManager:show(confirm_dialog)
end

function GrimmorySync:startMetadataRefresh()
    if not self:configurationReady() then
        self:promptConfiguration()
        return
    end

    self.abort_sync = false
    self.abort_notified = false

    local confirm_dialog
    confirm_dialog = ConfirmBox:new{
        text = _("Refresh metadata in existing books?\n\nThe plugin will download matched EPUB files again from the configured server and replace local files only after the download has been verified. Missing books are not downloaded here. The currently open book is skipped."),
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

function GrimmorySync:syncCompleteMessage(stats, downloaded, cleanup_result)
    cleanup_result = cleanup_result or {}
    local message = string.format(
        _("Sync complete.\n\nLocal: %d books\nServer: %d books\nDownloaded missing: %d books"),
        stats.local_count or 0,
        stats.remote_count or 0,
        downloaded or 0
    )

    if self.mirror_selected_sync_source == true then
        message = message .. string.format(
            _("\nMoved removed to trash: %d books"),
            cleanup_result.moved or 0
        )
        if (cleanup_result.skipped_open or 0) > 0 then
            message = message .. string.format(
                _("\nSkipped currently open: %d books"),
                cleanup_result.skipped_open or 0
            )
        end
        if (cleanup_result.failed or 0) > 0 then
            message = message .. string.format(
                _("\nMirror cleanup failed: %d books"),
                cleanup_result.failed or 0
            )
            if cleanup_result.last_error then
                message = message .. "\n" .. string.format(_("Latest error: %s"), tostring(cleanup_result.last_error))
            end
        end
        if (cleanup_result.moved or 0) > 0 and cleanup_result.trash_path then
            message = message .. "\n" .. string.format(_("Trash: %s"), cleanup_result.trash_path)
        end
    end

    return message .. self:apiMetadataWarning(stats.api_error)
end

function GrimmorySync:performSync()
    if self.sync_running or self.auto_refresh_running then
        UIManager:show(InfoMessage:new{
            text = _("Library Sync is already running."),
            timeout = 3,
        })
        return
    end
    self.sync_running = true
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
        
        local remote_books, err = self:fetchBooklistFromServer()
        
        if not remote_books then
            return false, err
        end
        
        if self.abort_sync then
            return false, ABORTED
        end
        
        logger.info("[GrimmorySync] Remote books found:", #remote_books)

        self:showProgressDialog(string.format(_("Fetching extra metadata from %s..."), self:serverName()))
        local enriched, enrich_result = self:enrichRemoteBooksWithBookApiMetadata(remote_books)
        local api_error
        if enriched then
            logger.info("[GrimmorySync] Book API metadata applied:", enrich_result)
        else
            logger.warn("[GrimmorySync] Continuing without Book API metadata:", enrich_result)
            api_error = enrich_result
        end

        if self.abort_sync then
            return false, ABORTED
        end

        local routing_ok, routing_err = self:validateDownloadRoutingMetadata(remote_books, api_error)
        if not routing_ok then
            return false, routing_err
        end
        
        self:showProgressDialog(string.format(
            _("Comparing local and server books...\n\nLocal: %d\nServer: %d\n\nTap Cancel to stop after the current step."),
            #local_books,
            #remote_books
        ))
        
        local missing, manifest = self:buildMissingBookQueue(local_books, remote_books)
        local cleanup_queue, cleanup_stats = self:buildMirrorCleanupQueue(local_books, remote_books, manifest)
        return true, {
            missing = missing,
            manifest = manifest,
            cleanup_queue = cleanup_queue,
            cleanup_stats = cleanup_stats,
            local_count = #local_books,
            remote_count = #remote_books,
            api_error = api_error,
        }
    end)
    
    self:closeProgressDialog()
    
    if not ok then
        UIManager:show(InfoMessage:new{
            text = string.format(_("Sync error: %s"), tostring(success)),
            timeout = 5,
        })
        logger.err("[GrimmorySync] Sync error:", success)
        self.sync_running = false
        return
    end
    
    if not success then
        if payload ~= ABORTED then
            UIManager:show(InfoMessage:new{
                text = string.format(_("Error: %s"), tostring(payload)),
                timeout = 5,
            })
            logger.err("[GrimmorySync] Error:", payload)
        end
        self.sync_running = false
        return
    end
    
    local stats = payload or {}
    local missing = stats.missing or {}
    local cleanup_queue = stats.cleanup_queue or {}
    local cleanup_stats = stats.cleanup_stats or {}

    local function finishWithMirrorCleanup(downloaded)
        local function showResult(cleanup_result)
            cleanup_result = cleanup_result or {}
            cleanup_result.skipped_open = (cleanup_result.skipped_open or 0)
                + (cleanup_stats.skipped_open or 0)
            if (downloaded or 0) > 0 or (cleanup_result.moved or 0) > 0 then
                self:refreshFileBrowserContent()
            end
            UIManager:show(InfoMessage:new{
                text = self:syncCompleteMessage(stats, downloaded or 0, cleanup_result),
                timeout = 5,
            })
            self.sync_running = false
        end

        if self.mirror_selected_sync_source == true and #cleanup_queue > 0 then
            self:moveMirrorCleanupAsync(cleanup_queue, stats.manifest, function(cleanup_ok, cleanup_result)
                self:closeProgressDialog()
                cleanup_result = cleanup_result or {}
                if not cleanup_ok and cleanup_result.error == ABORTED then
                    UIManager:show(InfoMessage:new{
                        text = string.format(
                            _("Sync canceled during mirror cleanup.\n\nDownloaded: %d books\nMoved to trash: %d books\nRemaining cleanup: %d books"),
                            downloaded or 0,
                            cleanup_result.moved or 0,
                            cleanup_result.remaining or 0
                        ),
                        timeout = 5,
                    })
                    self.sync_running = false
                    return
                end
                showResult(cleanup_result)
            end)
        else
            showResult({
                moved = 0,
                failed = 0,
                skipped_open = 0,
                trash_path = self:mirrorTrashPath(),
            })
        end
    end

    if #missing == 0 then
        finishWithMirrorCleanup(0)
        return
    end

    self:downloadMissingBooksAsync(missing, stats.manifest, function(done_ok, result)
        self:closeProgressDialog()
        result = result or {}

        if not done_ok then
            if result.error == ABORTED then
                UIManager:show(InfoMessage:new{
                    text = string.format(
                        _("Sync canceled.\n\nDownloaded: %d books\nRemaining: %d books"),
                        result.downloaded or 0,
                        result.remaining or 0
                    ),
                    timeout = 5,
                })
            else
                UIManager:show(InfoMessage:new{
                    text = string.format(_("Error: %s"), tostring(result.error or _("unknown"))),
                    timeout = 5,
                })
                logger.err("[GrimmorySync] Error:", result.error)
            end
            self.sync_running = false
            return
        end

        finishWithMirrorCleanup(result.downloaded or 0)
    end)
end

function GrimmorySync:performMetadataRefreshForFile(file_path)
    if self.sync_running or self.auto_refresh_running then
        UIManager:show(InfoMessage:new{
            text = _("Library Sync is already running."),
            timeout = 3,
        })
        return
    end

    self.sync_running = true
    self.abort_sync = false
    self.abort_notified = false

    local target_name = self:displayNameForPath(file_path)
    self:showProgressDialog(string.format(
        _("Preparing metadata refresh...\n\n%s"),
        target_name
    ))

    local ok, success, payload = pcall(function()
        if self:isCurrentDocumentPath(file_path) then
            return false, _("Close this book before refreshing its metadata.")
        end

        local local_book, target_err = self:localBookFromPath(file_path)
        if not local_book then
            return false, target_err
        end

        if self.abort_sync then
            return false, ABORTED
        end

        self:showProgressDialog(string.format(
            _("Fetching books from server...\n\n%s\n\nTap Cancel to stop after the current step."),
            target_name
        ))

        local remote_books, err = self:fetchBooklistFromServer()
        if not remote_books then
            return false, err
        end

        if self.abort_sync then
            return false, ABORTED
        end

        self:showProgressDialog(string.format(_("Fetching extra metadata from %s..."), self:serverName()))
        local enriched, enrich_result = self:enrichRemoteBooksWithBookApiMetadata(remote_books)
        local api_error
        if enriched then
            logger.info("[GrimmorySync] Book API metadata applied:", enrich_result)
        else
            logger.warn("[GrimmorySync] Continuing without Book API metadata:", enrich_result)
            api_error = enrich_result
        end

        if self.abort_sync then
            return false, ABORTED
        end

        self:showProgressDialog(string.format(
            _("Matching selected book...\n\n%s"),
            target_name
        ))

        local matched, skipped, manifest, queue_stats = self:buildMetadataRefreshQueue({ local_book }, remote_books, {
            skip_open_book = true,
        })

        return true, {
            matched = matched,
            manifest = manifest,
            queue_stats = queue_stats,
            skipped = skipped or 0,
            remote_count = #remote_books,
            target_name = target_name,
            api_error = api_error,
        }
    end)

    self:closeProgressDialog()

    if not ok then
        UIManager:show(InfoMessage:new{
            text = string.format(_("Metadata refresh error: %s"), tostring(success)),
            timeout = 5,
        })
        logger.err("[GrimmorySync] Metadata refresh error:", success)
        self.sync_running = false
        return
    end

    if not success then
        if payload ~= ABORTED then
            UIManager:show(InfoMessage:new{
                text = string.format(_("Error: %s"), tostring(payload)),
                timeout = 5,
            })
            logger.err("[GrimmorySync] Metadata refresh error:", payload)
        end
        self.sync_running = false
        return
    end

    local stats = payload or {}
    local matched = stats.matched or {}
    if #matched == 0 then
        local queue_stats = stats.queue_stats or {}
        local message
        if (queue_stats.skipped_open or 0) > 0 then
            message = string.format(
                _("Metadata refresh skipped.\n\n%s\n\nClose the book and try again."),
                stats.target_name or target_name
            )
        elseif (stats.skipped or 0) > 0 then
            message = string.format(
                _("Metadata is already up to date.\n\n%s"),
                stats.target_name or target_name
            )
        else
            local sync_source = (self.selected_feed and self.selected_feed ~= "")
                and (self.selected_feed_label ~= "" and self.selected_feed_label or self.selected_feed)
                or _("All books")
            message = string.format(
                _("No matching server book was found for this EPUB in the selected sync source.\n\nFile: %s\nSource: %s"),
                stats.target_name or target_name,
                sync_source
            )
        end

        UIManager:show(InfoMessage:new{
            text = message .. self:apiMetadataWarning(stats.api_error),
            timeout = 5,
        })
        self.sync_running = false
        return
    end

    self:refreshExistingMetadataAsync(matched, stats.skipped or 0, stats.manifest, function(done_ok, result)
        self:closeProgressDialog()
        result = result or {}

        if not done_ok then
            if result.error == ABORTED then
                UIManager:show(InfoMessage:new{
                    text = string.format(
                        _("Metadata refresh canceled.\n\nUpdated: %d books"),
                        result.refreshed or 0
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
            self.sync_running = false
            return
        end

        if (result.refreshed or 0) > 0 then
            self:refreshFileBrowserContent()
            local message = string.format(
                _("Metadata refreshed.\n\n%s"),
                stats.target_name or target_name
            ) .. self:apiMetadataWarning(stats.api_error)
            UIManager:show(InfoMessage:new{
                text = message,
                timeout = 5,
            })
        else
            local message = string.format(
                _("No file was replaced.\n\n%s"),
                stats.target_name or target_name
            ) .. self:apiMetadataWarning(stats.api_error)
            UIManager:show(InfoMessage:new{
                text = message,
                timeout = 5,
            })
        end

        self.sync_running = false
    end, { skip_open_book = true })
end

function GrimmorySync:performMetadataRefresh()
    if self.sync_running or self.auto_refresh_running then
        UIManager:show(InfoMessage:new{
            text = _("Library Sync is already running."),
            timeout = 3,
        })
        return
    end
    self.sync_running = true
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

        local remote_books, err = self:fetchBooklistFromServer()

        if not remote_books then
            return false, err
        end

        if self.abort_sync then
            return false, ABORTED
        end

        logger.info("[GrimmorySync] Remote books found:", #remote_books)

        self:showProgressDialog(string.format(_("Fetching extra metadata from %s..."), self:serverName()))
        local enriched, enrich_result = self:enrichRemoteBooksWithBookApiMetadata(remote_books)
        local api_error
        if enriched then
            logger.info("[GrimmorySync] Book API metadata applied:", enrich_result)
        else
            logger.warn("[GrimmorySync] Continuing without Book API metadata:", enrich_result)
            api_error = enrich_result
        end

        if self.abort_sync then
            return false, ABORTED
        end

        self:showProgressDialog(string.format(
            _("Matching existing books...\n\nLocal: %d\nServer: %d"),
            #local_books,
            #remote_books
        ))

        local matched, skipped, manifest, queue_stats = self:buildMetadataRefreshQueue(local_books, remote_books, {
            skip_open_book = true,
        })

        return true, {
            matched = matched,
            manifest = manifest,
            queue_stats = queue_stats,
            skipped = skipped or 0,
            local_count = #local_books,
            remote_count = #remote_books,
            api_error = api_error,
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
        self.sync_running = false
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
        self.sync_running = false
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
            self.sync_running = false
            return
        end

        self:syncAuthorImagesAsync(function(image_ok, image_result)
            self:closeProgressDialog()
            UIManager:show(InfoMessage:new{
                text = self:metadataRefreshMessage(stats, result, image_ok, image_result),
                timeout = 5,
            })
            self.sync_running = false
        end)
    end

    if #matched == 0 then
        finishWithAuthorImages({
            refreshed = 0,
            skipped = stats.skipped or 0,
            skipped_open = (stats.queue_stats and stats.queue_stats.skipped_open) or 0,
        })
        return
    end

    self:refreshExistingMetadataAsync(matched, stats.skipped or 0, stats.manifest, function(done_ok, result)
        self:closeProgressDialog()
        result = result or {}
        result.skipped_open = (result.skipped_open or 0)
            + ((stats.queue_stats and stats.queue_stats.skipped_open) or 0)
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
            self.sync_running = false
            return
        end

        finishWithAuthorImages(result)
    end, { skip_open_book = true })
end

function GrimmorySync:showStatus()
    local books = self:scanLocalBooks()
    local sync_source = (self.selected_feed and self.selected_feed ~= "")
        and (self.selected_feed_label ~= "" and self.selected_feed_label or self.selected_feed)
        or _("All books")
    local auto_refresh = {}
    if self.auto_refresh_on_startup == true then
        auto_refresh[#auto_refresh + 1] = _("startup")
    end
    local interval_label = self:autoRefreshIntervalLabel(self.auto_refresh_interval_hours)
    if self:autoRefreshIntervalSeconds() > 0 then
        auto_refresh[#auto_refresh + 1] = interval_label
    end
    local auto_refresh_text = #auto_refresh > 0 and table.concat(auto_refresh, ", ") or _("off")
    local api_username = self:apiCredentials()
    if api_username == "" then
        api_username = _("Not set")
    end
    local text = string.format(
        _("Server type: %s\nServer: %s\nOPDS user: %s\nAPI user: %s\nPath: %s\nLocal: %d books\nSync source: %s\nMirror selected sync source: %s\nMirror trash: %s\nFolder profile: %s\nFile naming: %s\nCustom rules: %s\nAutomatic metadata refresh: %s\nOPDS timestamp trigger: %s\nBookshelf author images: %s\nBookshelf image path: %s"),
        self:serverName(),
        self.server_url ~= "" and self.server_url or _("Not set"),
        self.username ~= "" and self.username or _("Not set"),
        api_username,
        self.local_path,
        #books,
        sync_source,
        self.mirror_selected_sync_source == true and _("on") or _("off"),
        self:mirrorTrashPath(),
        self:routingProfileLabel(self.routing_profile or ROUTING_PROFILE_FLAT),
        self:filenameProfileLabel(self.filename_profile or FILENAME_PROFILE_SYNC_DEFAULT),
        self.path_rules_file or DEFAULT_PATH_RULES_FILE,
        auto_refresh_text,
        self.auto_refresh_use_opds_updated == true and _("on") or _("off"),
        self.sync_author_images ~= false and _("on") or _("off"),
        self:authorImagesPath()
    )
    
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = 5,
    })
end

return GrimmorySync

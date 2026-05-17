local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local dump = require("dump")

local GrimmorySync = WidgetContainer:new{
    name = "grimmorysync",
    is_doc_only = false,
    abort_sync = false,
}

local SETTINGS_FILE = "/storage/emulated/0/koreader/grimmory_sync_settings.txt"
local LEGACY_SETTINGS_FILE = "/storage/emulated/0/koreader/booklore_sync_settings.txt"
local HISTORY_FILE = "/storage/emulated/0/koreader/grimmory_sync_history.lua"
local LEGACY_HISTORY_FILE = "/storage/emulated/0/koreader/booklore_sync_history.lua"
local MAX_HISTORY = 15

function GrimmorySync:loadSettings()
    local file = io.open(SETTINGS_FILE, "r") or io.open(LEGACY_SETTINGS_FILE, "r")
    if not file then
        return {
            server_url = "",
            username = "",
            password = "",
            local_path = "/storage/emulated/0/ePubs"
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
        local_path = settings.local_path or "/storage/emulated/0/ePubs"
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
            callback = function()
                self:openRecentBook(entry_ref)
            end,
        })
    end

    table.insert(items, {
        text = "———",
        enabled = false,
    })
    table.insert(items, {
        text = _("Rensa historik"),
        callback = function()
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

function GrimmorySync:init()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    
    local settings = self:loadSettings()
    self.server_url = settings.server_url
    self.username = settings.username
    self.password = settings.password
    self.local_path = settings.local_path
end

function GrimmorySync:addToMainMenu(menu_items)
    menu_items.grimmory_sync = {
        text = _("Grimmory Sync"),
        sorting_hint = "search",
        sub_item_table = {
            {
                text = _("Sync missing books"),
                callback = function()
                    self:startSync()
                end,
            },
            {
                text = _("Refresh existing metadata"),
                callback = function()
                    self:startMetadataRefresh()
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
                callback = function()
                    self:showServerConfig()
                end,
            },
            {
                text = _("Show status"),
                callback = function()
                    self:showStatus()
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

function GrimmorySync:makeRequest(endpoint)
    local ok_http, http = pcall(require, "socket.http")
    local ok_https, https = pcall(require, "ssl.https")
    local ok_ltn12, ltn12 = pcall(require, "ltn12")
    
    if not ok_http or not ok_ltn12 then
        return nil, "Cannot load HTTP libraries"
    end
    
    -- Build full URL
    local url = self.server_url .. endpoint
    
    -- Prepare headers
    local headers = {}
    if self.username ~= "" and self.password ~= "" then
        local mime = require("mime")
        headers["authorization"] = "Basic " .. mime.b64(self.username .. ":" .. self.password)
    end
    
    -- Choose appropriate request function based on protocol
    local request_func = url:match("^https://") and (ok_https and https.request or http.request) or http.request
    
    -- Collect response
    local response_body = {}
    local success, status_code, response_headers = request_func{
        url = url,
        sink = ltn12.sink.table(response_body),
        headers = headers,
    }
    
    -- Check result
    if not success then
        return nil, "Connection failed: " .. tostring(status_code)
    end
    
    if type(status_code) == "number" and status_code ~= 200 then
        return nil, "HTTP " .. status_code
    end
    
    return table.concat(response_body), nil
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
            
            -- Extract published year
            local published = entry:match("<published>(.-)</published>") or entry:match("<updated>(.-)</updated>")
            local year
            if published then
                year = published:match("(%d%d%d%d)")
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

function GrimmorySync:compareAndDownload(local_books, remote_books)
    local local_index = self:buildLocalBookIndex(local_books)

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
            "Laddar ner bok %d av %d...\n\n%s\n\nTryck för att avbryta",
            i,
            #missing,
            book.title
        ))
        
        if self:downloadBook(book) then
            count = count + 1
        end
    end
    
    return count, nil
end

function GrimmorySync:refreshExistingMetadata(local_books, remote_books)
    local local_index = self:buildLocalBookIndex(local_books)
    local matched = {}

    for _, remote in ipairs(remote_books) do
        local matched_book, matched_name, fuzzy = self:findLocalMatch(remote, local_index)
        if matched_book and matched_book.path then
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

    if #matched == 0 then
        return 0, nil
    end

    local count = 0
    for i, item in ipairs(matched) do
        if self.abort_sync then
            logger.info("[GrimmorySync] Metadata refresh aborted by user")
            return count, nil
        end

        self:showProgressDialog(string.format(
            "Uppdaterar metadata %d av %d...\n\n%s\n\nTryck för att avbryta",
            i,
            #matched,
            item.remote.title
        ))

        if self:downloadBook(item.remote, item.local_path, { record_history = false }) then
            count = count + 1
        end
    end

    return count, nil
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
    local download_url = self.server_url .. book.download_url
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
    
    -- Download using appropriate protocol
    local request_func = download_url:match("^https://") and (ok_https and https.request or http.request) or http.request
    
    local success, status_code, response_headers = request_func{
        url = download_url,
        sink = ltn12.sink.file(file),
        headers = headers,
    }
    
    -- Note: ltn12.sink.file closes the file automatically, so we don't close it manually
    
    -- Check result
    if not success or (type(status_code) == "number" and status_code ~= 200) then
        logger.err("[GrimmorySync] Download failed:", status_code or "unknown error")
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
    return true
end

function GrimmorySync:showProgressDialog(text)
    -- Always close and create new dialog since InfoMessage doesn't have setText
    if self.progress_dialog then
        UIManager:close(self.progress_dialog)
    end
    
    self.progress_dialog = InfoMessage:new{
        text = text,
        timeout = nil,  -- No auto-close
    }
    UIManager:show(self.progress_dialog)
    UIManager:forceRePaint()
end

function GrimmorySync:closeProgressDialog()
    if self.progress_dialog then
        UIManager:close(self.progress_dialog)
        self.progress_dialog = nil
    end
end

function GrimmorySync:startSync()
    if self.server_url == "" then
        UIManager:show(ConfirmBox:new{
            text = _("Server not configured!\n\nConfigure now?"),
            ok_text = _("Configure"),
            ok_callback = function()
                self:showServerConfig()
            end,
        })
        return
    end
    
    -- Reset abort flag
    self.abort_sync = false
    
    -- Show confirmation with cancel option
    UIManager:show(ConfirmBox:new{
        text = _("Synka saknade böcker?\n\nEndast böcker som saknas på enheten laddas ner. Du kan avbryta när som helst."),
        ok_text = _("Starta"),
        cancel_text = _("Avbryt"),
        ok_callback = function()
            self:performSync()
        end,
    })
end

function GrimmorySync:startMetadataRefresh()
    if self.server_url == "" then
        UIManager:show(ConfirmBox:new{
            text = _("Server not configured!\n\nConfigure now?"),
            ok_text = _("Configure"),
            ok_callback = function()
                self:showServerConfig()
            end,
        })
        return
    end

    self.abort_sync = false

    UIManager:show(ConfirmBox:new{
        text = _("Uppdatera metadata i befintliga böcker?\n\nPluginet laddar om matchade EPUB-filer från Grimmory och ersätter lokala filer först efter att nedladdningen har verifierats. Saknade böcker laddas inte ner här."),
        ok_text = _("Uppdatera"),
        cancel_text = _("Avbryt"),
        ok_callback = function()
            self:performMetadataRefresh()
        end,
    })
end

function GrimmorySync:performSync()
    self:showProgressDialog("Skannar lokala böcker...")
    
    local ok, success, count_or_err = pcall(function()
        -- Add abort button to progress dialog
        UIManager:scheduleIn(0.1, function()
            if self.progress_dialog then
                self.progress_dialog.dismiss_callback = function()
                    self.abort_sync = true
                    self:closeProgressDialog()
                    UIManager:show(InfoMessage:new{
                        text = _("Synk avbruten"),
                        timeout = 2,
                    })
                end
            end
        end)
        
        local local_books = self:scanLocalBooks()
        logger.info("[GrimmorySync] Local books found:", #local_books)
        
        if self.abort_sync then
            return false, "Avbruten"
        end
        
        self:showProgressDialog(string.format(
            "Hämtar böcker från server...\n\nLokala böcker: %d\n\nTryck för att avbryta",
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
            "Jämför och laddar ner...\n\nLokala: %d\nServern: %d\n\nTryck för att avbryta",
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

    local ok, success, count_or_err = pcall(function()
        UIManager:scheduleIn(0.1, function()
            if self.progress_dialog then
                self.progress_dialog.dismiss_callback = function()
                    self.abort_sync = true
                    self:closeProgressDialog()
                    UIManager:show(InfoMessage:new{
                        text = _("Metadatauppdatering avbruten"),
                        timeout = 2,
                    })
                end
            end
        end)

        local local_books = self:scanLocalBooks()
        logger.info("[GrimmorySync] Local books found:", #local_books)

        if self.abort_sync then
            return false, "Avbruten"
        end

        self:showProgressDialog(string.format(
            "Hämtar böcker från server...\n\nLokala böcker: %d\n\nTryck för att avbryta",
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
            "Matchar befintliga böcker...\n\nLokala: %d\nServern: %d\n\nTryck för att avbryta",
            #local_books,
            #remote_books
        ))

        local count, refresh_err = self:refreshExistingMetadata(local_books, remote_books)
        if refresh_err then
            return false, refresh_err
        end

        return true, { refreshed = count, local_count = #local_books, remote_count = #remote_books }
    end)

    self:closeProgressDialog()

    if not ok then
        UIManager:show(InfoMessage:new{
            text = _("Metadata refresh error: ") .. tostring(success),
            timeout = 5,
        })
        logger.err("[GrimmorySync] Metadata refresh error:", success)
        return
    end

    if not success then
        if count_or_err ~= "Avbruten" then
            UIManager:show(InfoMessage:new{
                text = _("Error: ") .. tostring(count_or_err),
                timeout = 5,
            })
            logger.err("[GrimmorySync] Metadata refresh error:", count_or_err)
        end
        return
    end

    local stats = count_or_err
    local message = string.format(
        "✓ Metadata uppdaterad!\n\nLokala: %d böcker\nServern: %d böcker\nUppdaterade: %d böcker",
        stats.local_count or 0,
        stats.remote_count or 0,
        stats.refreshed or 0
    )

    UIManager:show(InfoMessage:new{
        text = message,
        timeout = 5,
    })
end

function GrimmorySync:showStatus()
    local books = self:scanLocalBooks()
    local text = string.format(
        "Server: %s\nUser: %s\nPath: %s\nLocal: %d books",
        self.server_url ~= "" and self.server_url or "Not set",
        self.username ~= "" and self.username or "Not set",
        self.local_path,
        #books
    )
    
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = 5,
    })
end

return GrimmorySync

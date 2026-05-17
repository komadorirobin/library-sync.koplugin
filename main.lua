local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local dump = require("dump")

local BookloreSync = WidgetContainer:new{
    name = "bookloresync",
    is_doc_only = false,
    abort_sync = false,
}

local SETTINGS_FILE = "/storage/emulated/0/koreader/booklore_sync_settings.txt"
local HISTORY_FILE = "/storage/emulated/0/koreader/booklore_sync_history.lua"
local MAX_HISTORY = 15

function BookloreSync:loadSettings()
    local file = io.open(SETTINGS_FILE, "r")
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

function BookloreSync:saveSettings()
    local file = io.open(SETTINGS_FILE, "w")
    if not file then
        logger.warn("[BookloreSync] Cannot save settings")
        return
    end
    
    file:write("server_url=" .. self.server_url .. "\n")
    file:write("username=" .. self.username .. "\n")
    file:write("password=" .. self.password .. "\n")
    file:write("local_path=" .. self.local_path .. "\n")
    file:close()
end

function BookloreSync:loadHistory()
    local ok, history = pcall(dofile, HISTORY_FILE)
    if ok and type(history) == "table" then
        return history
    end
    return {}
end

function BookloreSync:saveHistory(history)
    local file = io.open(HISTORY_FILE, "w")
    if not file then
        logger.warn("[BookloreSync] Cannot save history")
        return
    end
    file:write("return " .. dump(history) .. "\n")
    file:close()
end

function BookloreSync:recordDownload(book, file_path)
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

function BookloreSync:getRecentBooksMenu()
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

function BookloreSync:openRecentBook(entry)
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

function BookloreSync:init()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    
    local settings = self:loadSettings()
    self.server_url = settings.server_url
    self.username = settings.username
    self.password = settings.password
    self.local_path = settings.local_path
end

function BookloreSync:addToMainMenu(menu_items)
    menu_items.booklore_sync = {
        text = _("Booklore Sync"),
        sorting_hint = "search",
        sub_item_table = {
            {
                text = _("Sync now"),
                callback = function()
                    self:startSync()
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

function BookloreSync:showServerConfig()
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Booklore Server URL"),
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

function BookloreSync:showUsernameConfig()
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

function BookloreSync:showPasswordConfig()
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

function BookloreSync:showPathConfig()
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

function BookloreSync:scanLocalBooks()
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then
        logger.err("[BookloreSync] Cannot load lfs")
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
    
    logger.info("[BookloreSync] Found", #books, "local books")
    return books
end

function BookloreSync:makeRequest(endpoint)
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

function BookloreSync:fetchBooklistFromBooklore()
    logger.info("[BookloreSync] Fetching books from:", self.server_url)
    logger.info("[BookloreSync] Username:", self.username)
    
    -- First, get the root OPDS catalog to find the "All Books" link
    local root_response, err = self:makeRequest("/api/v1/opds")
    
    -- If 401, try without authentication
    if err and err:match("401") then
        logger.info("[BookloreSync] Got 401, trying without auth...")
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
    
    logger.info("[BookloreSync] Following catalog link:", catalog_link)
    
    -- Fetch all pages with pagination support
    local books = {}
    local current_link = catalog_link
    local page_count = 0
    local max_pages = 100  -- Safety limit to prevent infinite loops
    
    while current_link and page_count < max_pages do
        page_count = page_count + 1
        logger.info("[BookloreSync] Fetching page", page_count, ":", current_link)
        
        local response, err = self:makeRequest(current_link)
        if not response then
            if page_count == 1 then
                return nil, err  -- Fail if first page fails
            else
                logger.warn("[BookloreSync] Failed to fetch page", page_count, ":", err)
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
                logger.info("[BookloreSync] Found book:", title, "by", author or "Unknown", "series:", series or "none", "->", download_link)
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
                logger.warn("[BookloreSync] Book without download link:", title)
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
            logger.info("[BookloreSync] Found next page link:", next_link)
            current_link = next_link
        else
            logger.info("[BookloreSync] No more pages, stopping at page", page_count)
            break
        end
    end
    
    if page_count >= max_pages then
        logger.warn("[BookloreSync] Reached maximum page limit (", max_pages, "), there may be more books")
    end
    
    logger.info("[BookloreSync] Found", #books, "remote books across", page_count, "pages")
    return books, nil
end

function BookloreSync:convertAuthorName(author)
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

function BookloreSync:generateTargetPath(book)
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

function BookloreSync:generatePossibleFilenames(book)
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

function BookloreSync:normalizeForComparison(str)
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

function BookloreSync:compareAndDownload(local_books, remote_books)
    -- Build a lookup table of all local filenames (just the filename, not full path)
    local local_lookup = {}
    local local_files_list = {}
    
    for _, book in ipairs(local_books) do
        -- Extract just the filename from the path (could be nested like "Author - Series/1 - Title.epub")
        local filename = book.filename:match("([^/]+)$") or book.filename
        local normalized = self:normalizeForComparison(filename)
        local_lookup[normalized] = true
        table.insert(local_files_list, normalized)
        logger.info("[BookloreSync] Local file:", normalized)
    end
    
    local missing = {}
    for _, remote in ipairs(remote_books) do
        local matched = false
        
        -- Generate all possible filenames for this book
        local possible_names = self:generatePossibleFilenames(remote)
        
        logger.info("[BookloreSync] Checking remote book:", remote.title, "author:", remote.author or "none", "series:", remote.series or "none")
        for idx, pname in ipairs(possible_names) do
            logger.info("[BookloreSync]   Possible name", idx, ":", pname)
        end
        
        -- Check if any of them exist locally
        for _, name in ipairs(possible_names) do
            local normalized = self:normalizeForComparison(name)
            
            -- Exact match
            if local_lookup[normalized] then
                logger.info("[BookloreSync] Already have:", remote.title, "(matched:", name, ")")
                matched = true
                break
            end
            
            -- Fuzzy match for title-only (when author is missing)
            -- Check if normalized name ends with " - Title.epub" pattern
            if normalized:match("^ %-") then
                -- This is a pattern like " - Akira, Vol. 1.epub"
                -- Check if any local file ends with this pattern
                for _, local_file in ipairs(local_files_list) do
                    if local_file:match(normalized:gsub("^ %- ", ".* %- ") .. "$") then
                        logger.info("[BookloreSync] Already have:", remote.title, "(fuzzy matched:", local_file, ")")
                        matched = true
                        break
                    end
                end
                if matched then break end
            end
        end
        
        if not matched then
            logger.info("[BookloreSync] Missing book:", remote.title)
            table.insert(missing, remote)
        end
    end
    
    if #missing == 0 then
        return 0, nil
    end
    
    local count = 0
    for i, book in ipairs(missing) do
        if self.abort_sync then
            logger.info("[BookloreSync] Sync aborted by user")
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

function BookloreSync:buildCalibrePath(book)
    -- Simply use generatePossibleFilenames to get the single unified format
    local possible = self:generatePossibleFilenames(book)
    local filename = possible[1] or (book.title .. ".epub")
    local full_path = self.local_path .. "/" .. filename
    
    return full_path, self.local_path, filename
end

function BookloreSync:downloadBook(book)
    local ok_http, http = pcall(require, "socket.http")
    local ok_https, https = pcall(require, "ssl.https")
    local ok_ltn12, ltn12 = pcall(require, "ltn12")
    
    if not ok_http or not ok_ltn12 then
        logger.err("[BookloreSync] Cannot load HTTP libraries")
        return false
    end
    
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then
        logger.err("[BookloreSync] Cannot load lfs")
        return false
    end
    
    logger.info("[BookloreSync] Downloading:", book.title)
    
    -- Generate target directory path based on genres/series
    local target_subdir = self:generateTargetPath(book)
    
    -- Generate all possible filenames and use the first one as default
    -- This ensures downloaded files match what we search for
    local possible_names = self:generatePossibleFilenames(book)
    local filename_only = possible_names[1] or (book.title .. ".epub")
    
    -- Combine subdirectory and filename
    local default_filename
    if target_subdir and target_subdir ~= "" then
        default_filename = target_subdir .. "/" .. filename_only
    else
        -- No subdirectory, place directly in ePubs root
        default_filename = filename_only
    end
    
    logger.info("[BookloreSync] Target path:", default_filename)
    
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
                    logger.err("[BookloreSync] Cannot create directory:", current, "error:", err or "unknown")
                    return false
                end
                logger.info("[BookloreSync] Created directory:", current)
            end
        end
        return true
    end
    
    -- Determine full path
    local full_path, dir_path
    if default_filename:match("/") then
        -- Filename includes subdirectory
        full_path = self.local_path .. "/" .. default_filename
        dir_path = full_path:match("(.+)/[^/]+$") or self.local_path
    else
        -- Simple filename
        full_path = self.local_path .. "/" .. default_filename
        dir_path = self.local_path
    end
    logger.info("[BookloreSync] Using generated filename:", default_filename)
    
    -- Create directories
    if not ensureDir(dir_path) then
        return false
    end
    
    -- Prepare download URL
    local download_url = self.server_url .. book.download_url
    logger.info("[BookloreSync] Download URL:", download_url)
    
    -- Prepare HTTP headers
    local headers = {}
    if self.username ~= "" and self.password ~= "" then
        local mime = require("mime")
        headers["authorization"] = "Basic " .. mime.b64(self.username .. ":" .. self.password)
    end
    
    -- Open file for writing
    local file = io.open(full_path, "wb")
    if not file then
        logger.err("[BookloreSync] Cannot create:", full_path)
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
        logger.err("[BookloreSync] Download failed:", status_code or "unknown error")
        pcall(os.remove, full_path)
        return false
    end
    
    -- Verify file was created and has content
    local attr = lfs.attributes(full_path)
    if not attr or attr.size == 0 then
        logger.err("[BookloreSync] Downloaded file is empty or missing")
        pcall(os.remove, full_path)
        return false
    end
    
    logger.info("[BookloreSync] OK:", book.title, "(" .. attr.size .. " bytes)")
    self:recordDownload(book, full_path)
    return true
end

function BookloreSync:showProgressDialog(text)
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

function BookloreSync:closeProgressDialog()
    if self.progress_dialog then
        UIManager:close(self.progress_dialog)
        self.progress_dialog = nil
    end
end

function BookloreSync:startSync()
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
        text = _("Start synkronisering?\n\nDu kan avbryta när som helst."),
        ok_text = _("Starta"),
        cancel_text = _("Avbryt"),
        ok_callback = function()
            self:performSync()
        end,
    })
end

function BookloreSync:performSync()
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
        logger.info("[BookloreSync] Local books found:", #local_books)
        
        if self.abort_sync then
            return false, "Avbruten"
        end
        
        self:showProgressDialog(string.format(
            "Hämtar böcker från server...\n\nLokala böcker: %d\n\nTryck för att avbryta",
            #local_books
        ))
        
        local remote_books, err = self:fetchBooklistFromBooklore()
        
        if not remote_books then
            return false, err
        end
        
        if self.abort_sync then
            return false, "Avbruten"
        end
        
        logger.info("[BookloreSync] Remote books found:", #remote_books)
        
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
        logger.err("[BookloreSync] Sync error:", success)
        return
    end
    
    if not success then
        if count_or_err ~= "Avbruten" then
            UIManager:show(InfoMessage:new{
                text = _("Error: ") .. tostring(count_or_err),
                timeout = 5,
            })
            logger.err("[BookloreSync] Error:", count_or_err)
        end
        return
    end
    
    local stats = count_or_err
    local message = string.format(
        "✓ Synk klar!\n\nLokala: %d böcker\nServern: %d böcker\nNedladdade: %d böcker",
        stats.local_count or 0,
        stats.remote_count or 0,
        stats.downloaded or 0
    )
    
    UIManager:show(InfoMessage:new{
        text = message,
        timeout = 5,
    })
end

function BookloreSync:showStatus()
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

return BookloreSync

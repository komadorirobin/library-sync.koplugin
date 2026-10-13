package.path = "./?.lua;./?/init.lua;" .. package.path

package.preload["ui/uimanager"] = function() return {} end
package.preload["ui/widget/infomessage"] = function() return {} end
package.preload["ui/widget/confirmbox"] = function() return {} end
package.preload["ui/widget/inputdialog"] = function() return {} end
package.preload["ui/widget/buttondialog"] = function() return {} end
package.preload["ui/widget/container/widgetcontainer"] = function()
    return { new = function(_, value) return value end }
end
package.preload["logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["gettext"] = function() return function(value) return value end end
package.preload["dump"] = function() return function() return "{}" end end
package.preload["grimmory_updater"] = function() return {} end
local decoded_json = {}
local fake_files = {}
local fake_dirs = {}
local fake_dir_entries = {}
local bookorbit_links = {}
local bookorbit_link_batch_sizes = {}
package.preload["util"] = function()
    return {
        partialMD5 = function(path)
            return "digest:" .. tostring(path)
        end,
    }
end
package.preload["bookorbit_state_manager"] = function()
    return {
        linkFiles = function(entries)
            bookorbit_link_batch_sizes[#bookorbit_link_batch_sizes + 1] = #(entries or {})
            for _, entry in ipairs(entries or {}) do
                bookorbit_links[#bookorbit_links + 1] = entry
            end
            return 1
        end,
        onDeviceMaps = function()
            return { byBookId = {}, byFileId = {} }
        end,
    }
end
package.preload["json"] = function()
    return { decode = function(body) return decoded_json[body] end }
end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path)
            if fake_files[path] then
                return { mode = "file", size = 10 }
            end
            if fake_dirs[path] then
                return { mode = "directory" }
            end
            return nil
        end,
        mkdir = function(path)
            fake_dirs[path] = true
            return true
        end,
        dir = function(path)
            local entries = fake_dir_entries[path] or {}
            local index = 0
            return function()
                index = index + 1
                return entries[index]
            end
        end,
    }
end
local http_requests = {}
package.preload["ltn12"] = function()
    return {
        sink = {
            table = function(target)
                return function(chunk)
                    if chunk then
                        target[#target + 1] = chunk
                    end
                    return 1
                end
            end,
        },
        source = {
            string = function(value)
                local done = false
                return function()
                    if done then
                        return nil
                    end
                    done = true
                    return value
                end
            end,
        },
    }
end
package.preload["socket.http"] = function()
    return {
        request = function(request)
            local body = request.source and request.source() or nil
            http_requests[#http_requests + 1] = {
                url = request.url,
                method = request.method,
                body = body,
            }
            if request.url == "http://redirect.example.com/api/v1/auth/login" then
                return 1, 301, { location = "https://redirect.example.com/api/v1/auth/login" }
            end
            return nil, "unexpected HTTP URL: " .. tostring(request.url)
        end,
    }
end
package.preload["ssl.https"] = function()
    return {
        request = function(request)
            local body = request.source and request.source() or nil
            http_requests[#http_requests + 1] = {
                url = request.url,
                method = request.method,
                body = body,
            }
            if request.url == "https://redirect.example.com/api/v1/auth/login" then
                request.sink("redirected-ok")
                return 1, 200, {}
            end
            return nil, "unexpected HTTPS URL: " .. tostring(request.url)
        end,
    }
end

local Providers = require("providers/init")
local plugin = dofile("main.lua")

-- `_` is the gettext function throughout main.lua; ignored return values must
-- not shadow it inside a function that later translates UI strings.
local main_file = assert(io.open("main.lua", "rb"))
local main_source = main_file:read("*a")
main_file:close()
for line in main_source:gmatch("[^\r\n]+") do
    if not line:find('local _ = require("gettext")', 1, true) then
        local declarations = line:match("^%s*local%s+([^=]+)%s*=")
        if declarations then
            for name in declarations:gmatch("[^,]+") do
                if name:match("^%s*_%s*$") then
                    error("local '_' shadows gettext: " .. line)
                end
            end
        end
    end
end

assert(Providers.get("grimmory").opds_root == "/api/v1/opds")
assert(Providers.get("grimmory").api_credentials_separate == true)
assert(Providers.get("bookorbit").book_api.endpoint == "/api/v1/books/query")
assert(Providers.get("bookorbit").api_credentials_separate == true)
assert(Providers.get("bookorbit").api_fallback_to_opds_credentials == true)
assert(Providers.get("bookorbit").author_upload_api.endpoint:match("hasPhoto") == nil)
assert(Providers.get("bookorbit").author_image_upload_path(17) == "/api/v1/authors/17/image")

local redirected, redirect_err = plugin:httpRequest("http://redirect.example.com/api/v1/auth/login", {
    method = "POST",
    body = '{"username":"account-user","password":"account-password"}',
    headers = {
        ["content-type"] = "application/json",
    },
})
assert(redirected == "redirected-ok", tostring(redirect_err))
assert(#http_requests == 2)
assert(http_requests[1].method == "POST")
assert(http_requests[2].method == "POST")
assert(http_requests[2].body:match("account%-user"))

plugin.server_type = "grimmory"
plugin.server_url = "https://grimmory.example.com"
plugin.username = "opds-user"
plugin.password = "opds-password"
plugin.api_username = "account-user"
plugin.api_password = "account-password"
local captured_login_body
decoded_json["api-login-ok"] = { accessToken = "token" }
plugin.httpRequest = function(_, url, options)
    captured_login_body = options.body
    return "api-login-ok", nil
end
local token, login_err = plugin:loginToServerApi()
assert(token == "token", tostring(login_err))
assert(captured_login_body:match('"username":"account%-user"'))
assert(captured_login_body:match('"password":"account%-password"'))
assert(plugin:apiMetadataWarning("HTTP 400"):match("HTTP 400"))
plugin.api_username = ""
plugin.api_password = ""
assert(plugin:apiMetadataWarning("HTTP 400") == "")
plugin.local_path = "/library"
plugin.selected_feed = "/api/v1/opds/shelves/1"
plugin.selected_feed_label = "Shelf: Kids"
plugin.mirror_selected_sync_source = true
local tracked_manifest = { books = {} }
assert(plugin:trackManifestEntryScope(tracked_manifest, "/library/keep.epub", {
    book_id = "1",
    title = "Keep",
    author = "Author",
}) == true)
assert(tracked_manifest.books["/library/keep.epub"].remote_key == "id:1")
assert(tracked_manifest.books["/library/keep.epub"].sync_source == "/api/v1/opds/shelves/1")
assert(tracked_manifest.books["/library/keep.epub"].signature == nil)

local remove_fields = plugin:manifestScopeFields({ book_id = "2", title = "Remove" })
local other_source_fields = plugin:manifestScopeFields({ book_id = "3", title = "Other" })
other_source_fields.sync_source = "/api/v1/opds/shelves/other"
other_source_fields.sync_scope_key = table.concat({
    other_source_fields.server_type,
    other_source_fields.server_url,
    other_source_fields.sync_source,
}, string.char(31))
tracked_manifest.books["/library/remove.epub"] = {
    title = "Remove",
    remote_key = remove_fields.remote_key,
    server_type = remove_fields.server_type,
    server_url = remove_fields.server_url,
    sync_source = remove_fields.sync_source,
    sync_scope_key = remove_fields.sync_scope_key,
}
tracked_manifest.books["/library/other.epub"] = {
    title = "Other",
    remote_key = other_source_fields.remote_key,
    server_type = other_source_fields.server_type,
    server_url = other_source_fields.server_url,
    sync_source = other_source_fields.sync_source,
    sync_scope_key = other_source_fields.sync_scope_key,
}
fake_files["/library/remove.epub"] = true
fake_files["/library/other.epub"] = true
local cleanup_queue, cleanup_stats = plugin:buildMirrorCleanupQueue(
    {
        { path = "/library/remove.epub", filename = "remove.epub" },
        { path = "/library/other.epub", filename = "other.epub" },
    },
    {
        { book_id = "1", title = "Keep", author = "Author" },
    },
    tracked_manifest
)
assert(#cleanup_queue == 1)
assert(cleanup_queue[1].path == "/library/remove.epub")
assert(cleanup_stats.skipped_open == 0)

plugin.server_type = "bookorbit"
plugin.server_url = "https://books.example.com"
plugin.username = "opds-user"
plugin.password = "opds-password"
plugin.api_username = "account-user"
plugin.api_password = "account-password"
plugin.filename_profile = "grimmory_file"

assert(plugin:serverName() == "BookOrbit")
assert(plugin:configurationReady() == true)
assert(plugin:buildServerUrl("/api/v1/opds") == "https://books.example.com/api/v1/opds")
plugin.server_url = "https://books.example.com/api/v1/opds"
assert(plugin:buildServerUrl("/api/v1/opds") == "https://books.example.com/api/v1/opds")
plugin.server_url = "https://books.example.com"

local fallback_login_attempts = {}
decoded_json["bookorbit-opds-login-ok"] = { accessToken = "opds-token" }
plugin.httpRequest = function(_, url, options)
    fallback_login_attempts[#fallback_login_attempts + 1] = options.body
    assert(url == "https://books.example.com/api/v1/auth/login")
    if options.body:match("account%-user") then
        return nil, "HTTP 401"
    end
    if options.body:match("opds%-user") then
        return "bookorbit-opds-login-ok", nil
    end
    return nil, "unexpected body"
end
local fallback_token, fallback_err = plugin:loginToServerApi()
assert(fallback_token == "opds-token", tostring(fallback_err))
assert(#fallback_login_attempts == 2)

plugin.routing_profile = "genre_series"
local routing_ok, routing_err = plugin:validateDownloadRoutingMetadata({ { title = "No genres", genres = {} } }, "HTTP 401")
assert(routing_ok == false)
assert(routing_err:match("genre metadata"))
assert(routing_err:match("HTTP 401"))
local routing_ok_with_genre = assert(plugin:validateDownloadRoutingMetadata({ { genres = { "Manga" } } }, nil))
assert(routing_ok_with_genre == true)
plugin.routing_profile = "author"
local author_routing_ok = assert(plugin:validateDownloadRoutingMetadata({ { genres = {} } }, "HTTP 401"))
assert(author_routing_ok == true)

local entry = [[
<entry>
  <title>The Apollo Murders</title>
  <id>urn:bookorbit:book:42</id>
  <link rel="http://opds-spec.org/sort/series" href="/api/v1/opds/catalog?series=Apollo" title="Apollo #2"/>
  <link rel="http://opds-spec.org/acquisition" href="/api/v1/opds/42/download?fileId=9" type="application/epub+zip"/>
</entry>
]]

local series, series_index = plugin:seriesFromOpdsEntry(entry)
assert(series == "Apollo")
assert(series_index == "2")
assert(plugin:bookIdFromOpds(entry, "/api/v1/opds/42/download?fileId=9") == "42")
assert(plugin:bookFileIdFromOpds(entry, "/api/v1/opds/42/download?fileId=9") == "9")
assert(plugin:isLikelyBookDownloadLink({
    rel = "http://opds-spec.org/acquisition",
    href = "/api/v1/opds/42/download?fileId=10",
    type = "application/pdf",
}) == false)
local cbz_link_ok, cbz_link_format = plugin:isLikelyBookDownloadLink({
    rel = "http://opds-spec.org/acquisition",
    href = "/api/v1/opds/100/download?fileId=200",
    type = "application/vnd.comicbook+zip",
})
assert(cbz_link_ok == true)
assert(cbz_link_format == "cbz")
assert(plugin:isSyncBookPath("/library/Manga.cbz") == true)
assert(plugin:isSyncBookPath("/library/Book.epub") == true)
assert(plugin:isSyncBookPath("/library/Document.pdf") == false)

assert(plugin:contentDispositionFilename({
    ["Content-Disposition"] = 'attachment; filename="Server Book.epub"',
}) == "Server Book.epub")
assert(plugin:contentDispositionFilename({
    ["content-disposition"] = "attachment; FILENAME*=utf-8''Manga%20Volume%201.cbz",
}) == "Manga Volume 1.cbz")

local response_named_epub = { file_extension = "epub" }
assert(plugin:downloadPathFromResponse(
    response_named_epub,
    nil,
    "/library/Fallback.epub",
    "/library",
    { ["content-disposition"] = 'attachment; filename="Server Book.epub"' }
) == "/library/Server Book.epub")
assert(plugin:downloadPathFromResponse(
    response_named_epub,
    "/library/Existing.epub",
    "/library/Existing.epub",
    "/library",
    { ["content-disposition"] = 'attachment; filename="Renamed.epub"' }
) == "/library/Existing.epub")
assert(plugin:downloadPathFromResponse(
    response_named_epub,
    nil,
    "/library/Fallback.epub",
    "/library",
    { ["content-disposition"] = 'attachment; filename="Wrong.pdf"' }
) == "/library/Fallback.epub")

local response_named_cbz = { file_extension = "cbz" }
assert(plugin:downloadPathFromResponse(
    response_named_cbz,
    nil,
    "/library/Fallback.cbz",
    "/library",
    { ["content-disposition"] = 'attachment; filename="Server Manga.cbz"' }
) == "/library/Server Manga.cbz")

local root_feed = [[
<feed>
  <entry>
    <title>All Books</title>
    <link rel="subsection" href="/api/v1/opds/catalog?page=1&amp;size=50" type="application/atom+xml;profile=opds-catalog"/>
  </entry>
</feed>
]]
local catalog_feed = [[
<feed>
  <entry>
    <title>The Apollo Murders</title>
    <id>urn:bookorbit:book:42</id>
    <updated>2026-06-26T12:00:00.000Z</updated>
    <author><name>Chris Hadfield</name></author>
    <content type="text">A lunar thriller.</content>
    <link rel="http://opds-spec.org/sort/series" href="/api/v1/opds/catalog?series=Apollo" title="Apollo #2"/>
    <link rel="http://opds-spec.org/acquisition" href="/api/v1/opds/42/download?fileId=8" type="application/pdf"/>
    <link rel="http://opds-spec.org/acquisition" href="/api/v1/opds/42/download?fileId=9" type="application/epub+zip"/>
  </entry>
</feed>
]]
local responses = {
    ["/api/v1/opds"] = root_feed,
    ["/api/v1/opds/catalog?page=1&size=50"] = catalog_feed,
}
plugin.makeRequest = function(_, endpoint)
    return responses[endpoint], responses[endpoint] and nil or "unexpected endpoint"
end
plugin.selected_feed = ""
plugin.selected_feed_label = ""
plugin.mirror_selected_sync_source = false
local parsed_books = assert(plugin:fetchBooklistFromServer())
assert(#parsed_books == 1)
assert(parsed_books[1].book_id == "42")
assert(parsed_books[1].book_file_id == "9")
assert(parsed_books[1].series == "Apollo")
assert(parsed_books[1].series_index == "2")
assert(parsed_books[1].download_url == "/api/v1/opds/42/download?fileId=9")

local linked_path = "/library/The Apollo Murders.epub"
fake_files[linked_path] = true
local linked_manifest = { books = {} }
plugin:storeManifestEntry(linked_manifest, linked_path, parsed_books[1])
assert(linked_manifest.books[linked_path].bookorbit_book_id == "42")
assert(linked_manifest.books[linked_path].bookorbit_file_id == "9")
assert(plugin:queueBookOrbitRegistration(linked_path, parsed_books[1]) == true)
local registration_ok, registration = plugin:flushBookOrbitRegistrationQueue(linked_manifest)
assert(registration_ok == true)
assert(registration.linked == 1)
assert(#bookorbit_links == 1)
assert(bookorbit_links[1].bookId == 42)
assert(bookorbit_links[1].bookFileId == 9)
assert(bookorbit_links[1].file == linked_path)
assert(bookorbit_links[1].digest == "digest:" .. linked_path)
assert(linked_manifest.books[linked_path].bookorbit_digest == "digest:" .. linked_path)

bookorbit_links = {}
bookorbit_link_batch_sizes = {}
local linked_cbz_path = "/library/Manga/The Apollo Murders.cbz"
local linked_cbz = {
    book_id = "43",
    book_file_id = "10",
    title = "The Apollo Murders",
    author = "Chris Hadfield",
    file_extension = "cbz",
}
fake_files[linked_cbz_path] = true
local linked_cbz_manifest = { books = {} }
plugin:storeManifestEntry(linked_cbz_manifest, linked_cbz_path, linked_cbz)
assert(plugin:queueBookOrbitRegistration(linked_cbz_path, linked_cbz) == true)
local cbz_registration_ok, cbz_registration = plugin:flushBookOrbitRegistrationQueue(linked_cbz_manifest)
assert(cbz_registration_ok == true)
assert(cbz_registration.linked == 1)
assert(#bookorbit_links == 1)
assert(bookorbit_links[1].file == linked_cbz_path)
assert(bookorbit_links[1].bookId == 43)
assert(bookorbit_links[1].bookFileId == 10)

bookorbit_links = {}
bookorbit_link_batch_sizes = {}
local bulk_manifest = { books = {} }
plugin.bookorbit_link_queue = {}
for index = 1, 205 do
    local path = "/library/bulk-" .. index .. ".epub"
    local book = {
        book_id = tostring(1000 + index),
        book_file_id = tostring(2000 + index),
        title = "Bulk " .. index,
    }
    bulk_manifest.books[path] = {}
    plugin.bookorbit_link_queue[path] = {
        path = path,
        digest = "bulk-digest-" .. index,
        book = book,
        size = 10,
    }
end
local bulk_ok, bulk_result = plugin:flushBookOrbitRegistrationQueue(bulk_manifest)
assert(bulk_ok == true)
assert(bulk_result.linked == 205)
assert(#bookorbit_links == 205)
assert(#bookorbit_link_batch_sizes == 3)
assert(bookorbit_link_batch_sizes[1] == 100)
assert(bookorbit_link_batch_sizes[2] == 100)
assert(bookorbit_link_batch_sizes[3] == 5)

local legacy_bookorbit_entry = {
    remote_key = "id:42",
    download_url = "/api/v1/opds/42/download?fileId=9",
}
assert(plugin:bookOrbitBookId(legacy_bookorbit_entry) == "42")
assert(plugin:bookOrbitFileId(legacy_bookorbit_entry) == "9")

local paginated_first_page = catalog_feed:gsub(
    "</feed>",
    '<link rel="next" href="/api/v1/opds/catalog?page=2&amp;size=50"/></feed>'
)
plugin.makeRequest = function(_, endpoint)
    if endpoint == "/api/v1/opds" then return root_feed, nil end
    if endpoint == "/api/v1/opds/catalog?page=1&size=50" then return paginated_first_page, nil end
    if endpoint == "/api/v1/opds/catalog?page=2&size=50" then return nil, "HTTP 503" end
    return nil, "unexpected endpoint"
end
local partial_books, partial_err = plugin:fetchBooklistFromServer()
assert(partial_books == nil)
assert(partial_err:match("page 2"))
assert(partial_err:match("before making local changes"))

local retry_attempts = 0
local retry_second_page = catalog_feed:gsub("42", "43")
plugin.makeRequest = function(_, endpoint)
    if endpoint == "/api/v1/opds" then return root_feed, nil end
    if endpoint == "/api/v1/opds/catalog?page=1&size=50" then return paginated_first_page, nil end
    if endpoint == "/api/v1/opds/catalog?page=2&size=50" then
        retry_attempts = retry_attempts + 1
        if retry_attempts == 1 then return nil, "HTTP 503" end
        return retry_second_page, nil
    end
    return nil, "unexpected endpoint"
end
local retried_books = assert(plugin:fetchBooklistFromServer())
assert(retry_attempts == 2)
assert(#retried_books == 2)

local incomplete_total_feed = catalog_feed:gsub(
    "<feed>",
    '<feed xmlns:opensearch="http://a9.com/-/spec/opensearch/1.1/"><opensearch:totalResults>2</opensearch:totalResults>'
)
plugin.makeRequest = function(_, endpoint)
    if endpoint == "/api/v1/opds" then return root_feed, nil end
    if endpoint == "/api/v1/opds/catalog?page=1&size=50" then return incomplete_total_feed, nil end
    return nil, "unexpected endpoint"
end
local incomplete_books, incomplete_err = plugin:fetchBooklistFromServer()
assert(incomplete_books == nil)
assert(incomplete_err:match("received 1 of 2 entries"))

plugin.mirror_selected_sync_source = true
plugin.makeRequest = function(_, endpoint)
    return responses[endpoint], responses[endpoint] and nil or "unexpected endpoint"
end
local unverified_books, unverified_err = plugin:fetchBooklistFromServer()
assert(unverified_books == nil)
assert(unverified_err:match("total result count"))

local unsupported_format_feed = [[
<feed xmlns:opensearch="http://a9.com/-/spec/opensearch/1.1/">
  <opensearch:totalResults>2</opensearch:totalResults>
  <entry>
    <title>PDF book</title>
    <id>urn:bookorbit:book:99</id>
    <author><name>PDF Author</name></author>
    <link rel="http://opds-spec.org/acquisition" href="/api/v1/opds/99/download?fileId=199" type="application/pdf"/>
  </entry>
  <entry>
    <title>CBZ book</title>
    <id>urn:bookorbit:book:100</id>
    <author><name>CBZ Author</name></author>
    <link rel="http://opds-spec.org/acquisition" href="/api/v1/opds/100/download?fileId=200" type="application/vnd.comicbook+zip"/>
  </entry>
</feed>
]]
plugin.makeRequest = function(_, endpoint)
    if endpoint == "/api/v1/opds" then return root_feed, nil end
    if endpoint == "/api/v1/opds/catalog?page=1&size=50" then return unsupported_format_feed, nil end
    return nil, "unexpected endpoint"
end
local unsupported_books, unsupported_err, unsupported_stats = plugin:fetchBooklistFromServer()
assert(unsupported_books, tostring(unsupported_err))
assert(#unsupported_books == 1)
assert(unsupported_books[1].book_id == "100")
assert(unsupported_books[1].file_extension == "cbz")
assert(unsupported_books[1].download_url == "/api/v1/opds/100/download?fileId=200")
assert(plugin:preferredDownloadFilename(unsupported_books[1]) == "CBZ book - CBZ Author.cbz")
assert(unsupported_stats.entries_seen == 2)
assert(unsupported_stats.unsupported_entries == 1)
assert(unsupported_stats.remote_keys["id:99"] == true)
assert(unsupported_stats.remote_keys["id:100"] == true)

local unsupported_local_path = "/library/PDF book - PDF Author.epub"
local unsupported_manifest = { books = {} }
assert(plugin:trackManifestEntryScope(unsupported_manifest, unsupported_local_path, {
    book_id = "99",
    title = "PDF book",
    author = "PDF Author",
}) == true)
fake_files[unsupported_local_path] = true
local unsupported_cleanup = plugin:buildMirrorCleanupQueue(
    { { path = unsupported_local_path, filename = "PDF book - PDF Author.epub" } },
    unsupported_books,
    unsupported_manifest,
    unsupported_stats.remote_keys
)
assert(#unsupported_cleanup == 0)

local unidentified_feed = [[
<feed xmlns:opensearch="http://a9.com/-/spec/opensearch/1.1/">
  <opensearch:totalResults>1</opensearch:totalResults>
  <entry><updated>2026-08-28T08:00:00Z</updated></entry>
</feed>
]]
plugin.makeRequest = function(_, endpoint)
    if endpoint == "/api/v1/opds" then return root_feed, nil end
    if endpoint == "/api/v1/opds/catalog?page=1&size=50" then return unidentified_feed, nil end
    return nil, "unexpected endpoint"
end
local unidentified_books, unidentified_err = plugin:fetchBooklistFromServer()
assert(unidentified_books == nil)
assert(unidentified_err:match("could not identify 1 OPDS catalog entries"))
plugin.mirror_selected_sync_source = false

plugin.makeRequest = function(_, endpoint)
    return responses[endpoint], responses[endpoint] and nil or "unexpected endpoint"
end

local bookorbit = Providers.get("bookorbit")
local original_book_page_size = bookorbit.book_api.page_size
local original_author_page_size = bookorbit.author_api.page_size
local original_upload_author_page_size = bookorbit.author_upload_api.page_size
bookorbit.book_api.page_size = 2
bookorbit.author_api.page_size = 2
bookorbit.author_upload_api.page_size = 2
decoded_json["book-page-0"] = { items = { { id = 1 }, { id = 2 } }, total = 3 }
decoded_json["book-page-1"] = { items = { { id = 3 } }, total = 3 }
decoded_json["author-page-0"] = { items = { { id = 1 }, { id = 2 } }, total = 3 }
decoded_json["author-page-1"] = { items = { { id = 3 } }, total = 3 }
plugin.httpRequest = function(_, url, options)
    if url:match("/books/query$") then
        return options.body:match('"page":1') and "book-page-1" or "book-page-0", nil
    end
    if url:match("/authors%?") then
        return url:match("page=1") and "author-page-1" or "author-page-0", nil
    end
    return nil, "unexpected URL: " .. tostring(url)
end
local api_books = assert(plugin:fetchBookMetadataFromServerApi("token"))
local api_authors = assert(plugin:fetchAuthorsFromServer("token"))
assert(#api_books == 3)
assert(#api_authors == 3)
local upload_api_authors = assert(plugin:fetchAuthorsFromServer(
    "token",
    bookorbit.author_upload_api,
    "test upload"
))
assert(#upload_api_authors == 3)

assert(plugin:metadataRefreshApiGuard(false, "HTTP 503", 200):match("stopped before replacing"))
assert(plugin:metadataRefreshApiGuard(true, 190, 200) == nil)
assert(plugin:metadataRefreshApiGuard(true, 189, 200):match("matched only 189 of 200"))
local saved_api_username, saved_api_password = plugin.api_username, plugin.api_password
plugin.api_username, plugin.api_password = "", ""
assert(plugin:metadataRefreshApiGuard(false, "HTTP 401", 200) == nil)
plugin.api_username, plugin.api_password = saved_api_username, saved_api_password
local metadata_queue_100 = {}
for i = 1, 100 do metadata_queue_100[i] = {} end
local metadata_queue_25 = {}
for i = 1, 25 do metadata_queue_25[i] = {} end
local metadata_queue_99 = {}
for i = 1, 99 do metadata_queue_99[i] = {} end
assert(plugin:isLargeMetadataRefresh(metadata_queue_100, 1000) == true)
assert(plugin:isLargeMetadataRefresh(metadata_queue_25, 100) == true)
assert(plugin:isLargeMetadataRefresh(metadata_queue_99, 1000) == false)

decoded_json["book-incomplete-page-0"] = { items = { { id = 1 }, { id = 2 } }, total = 3 }
decoded_json["book-incomplete-page-1"] = { items = {}, total = 3 }
plugin.httpRequest = function(_, url, options)
    if url:match("/books/query$") then
        return options.body:match('"page":1') and "book-incomplete-page-1" or "book-incomplete-page-0", nil
    end
    return nil, "unexpected URL: " .. tostring(url)
end
local incomplete_api_books, incomplete_api_err = plugin:fetchBookMetadataFromServerApi("token")
assert(incomplete_api_books == nil)
assert(incomplete_api_err:match("received 2 of 3 books"))

bookorbit.book_api.page_size = original_book_page_size
bookorbit.author_api.page_size = original_author_page_size
bookorbit.author_upload_api.page_size = original_upload_author_page_size

local author_image_dir = "/library/.bookshelf-images/authors"
fake_dirs[author_image_dir] = true
fake_dir_entries[author_image_dir] = { ".", "..", ".temporary", "notes.txt", "Isaac Asimov.jpg" }
fake_files[author_image_dir .. "/Isaac Asimov.jpg"] = true
local indexed_author_images = assert(plugin:localAuthorImageIndex())
assert(#indexed_author_images.files == 1)
assert(indexed_author_images.files[1].stem_key == "isaac asimov")
local asimov_image = indexed_author_images.files[1]
local upload_plan = plugin:buildAuthorImageUploadPlan({
    { id = 10, name = "Isaac Asimov", sortName = "Asimov, Isaac", hasPhoto = false },
    { id = 11, name = "Frank Herbert", hasPhoto = true },
    { id = 12, name = "No Local Image", hasPhoto = false },
}, {
    files = indexed_author_images.files,
    by_stem = indexed_author_images.by_stem,
})
assert(#upload_plan.queue == 1)
assert(upload_plan.queue[1].author.id == 10)
assert(upload_plan.existing == 1)
assert(upload_plan.no_local == 1)
assert(upload_plan.ambiguous == 0)

local ambiguous_plan = plugin:buildAuthorImageUploadPlan({
    { id = 20, name = "Shared Name", hasPhoto = false },
    { id = 21, name = "Shared Name", hasPhoto = false },
}, {
    files = {
        {
            path = "/library/.bookshelf-images/authors/Shared Name.jpg",
            filename = "Shared Name.jpg",
            stem = "Shared Name",
            stem_key = "shared name",
            extension = "jpg",
            size = 4,
        },
    },
    by_stem = {
        ["shared name"] = {
            {
                path = "/library/.bookshelf-images/authors/Shared Name.jpg",
                filename = "Shared Name.jpg",
                stem = "Shared Name",
                stem_key = "shared name",
                extension = "jpg",
                size = 4,
            },
        },
    },
})
assert(#ambiguous_plan.queue == 0)
assert(ambiguous_plan.ambiguous == 2)

local upload_image_path = os.tmpname() .. ".jpg"
local upload_image_file = assert(io.open(upload_image_path, "wb"))
assert(upload_image_file:write("JPEG"))
upload_image_file:close()
local captured_upload
plugin.httpRequest = function(_, url, options)
    local source, source_err = options.source_factory()
    assert(source, tostring(source_err))
    local chunks = {}
    while true do
        local chunk, chunk_err = source()
        assert(not chunk_err, tostring(chunk_err))
        if not chunk then break end
        chunks[#chunks + 1] = chunk
    end
    captured_upload = {
        url = url,
        method = options.method,
        headers = options.headers,
        body = table.concat(chunks),
        content_length = options.content_length,
    }
    return "{}", nil
end
plugin.abort_sync = false
local upload_ok, upload_err = plugin:uploadAuthorImage({ id = 10, name = "Isaac Asimov" }, {
    path = upload_image_path,
    filename = "Isaac Asimov.jpg",
    extension = "jpg",
    size = 4,
}, "upload-token")
pcall(os.remove, upload_image_path)
assert(upload_ok == true, tostring(upload_err))
assert(captured_upload.url == "https://books.example.com/api/v1/authors/10/image")
assert(captured_upload.method == "POST")
assert(captured_upload.headers.authorization == "Bearer upload-token")
assert(captured_upload.headers["content-type"]:match("multipart/form%-data"))
assert(captured_upload.body:match('name="file"'))
assert(captured_upload.body:match('filename="Isaac Asimov%.jpg"'))
assert(captured_upload.body:match("Content%-Type: image/jpeg"))
assert(captured_upload.body:match("JPEG", 1, true))
assert(captured_upload.content_length == #captured_upload.body)

package.loaded["json"] = nil
package.loaded["dkjson"] = nil
package.loaded["cjson"] = nil
package.loaded["rapidjson"] = nil
package.preload["json"] = function() error("json unavailable") end
package.preload["dkjson"] = function() error("dkjson unavailable") end
package.preload["cjson"] = function() error("cjson unavailable") end
package.preload["rapidjson"] = function() error("rapidjson unavailable") end
plugin.httpRequest = function(_, url, options)
    if url:match("/auth/login$") then
        return '{"accessToken":"fallback-json-token"}', nil
    end
    if url:match("/books/query$") then
        return '{"items":[{"id":7,"title":"Fallback JSON","authors":["Parser Author"],"genres":["Fiction"],"tags":["Parsed"],"seriesName":"Parser Series","seriesIndex":1}],"total":1}', nil
    end
    return nil, "unexpected URL: " .. tostring(url)
end
local fallback_json_token = assert(plugin:loginToServerApi())
assert(fallback_json_token == "fallback-json-token")
local fallback_json_books = assert(plugin:fetchBookMetadataFromServerApi(fallback_json_token))
assert(#fallback_json_books == 1)
assert(fallback_json_books[1].genres[1] == "Fiction")
assert(fallback_json_books[1].tags[1] == "Parsed")
assert(fallback_json_books[1].authors[1] == "Parser Author")

local remote = {
    book_id = "42",
    title = "The Apollo Murders",
    author = "Chris Hadfield",
    genres = {},
}
local count = plugin:applyBookApiMetadata({ remote }, {
    {
        id = 42,
        title = "The Apollo Murders",
        authors = { "Chris Hadfield" },
        seriesName = "Apollo",
        seriesIndex = 2,
        genres = { "Science Fiction" },
        tags = { "Space" },
        hardcoverId = "the-apollo-murders",
        hardcoverEditionId = "12345",
    },
})

assert(count == 1)
assert(remote.series == "Apollo")
assert(remote.series_index == "2")
assert(remote.genres[1] == "Science Fiction")
assert(remote.genres[2] == "Space")
assert(remote.hardcover_id == "the-apollo-murders")
assert(remote.hardcover_edition_id == "12345")
assert(plugin:preferredDownloadFilename(remote) == "The Apollo Murders - Chris Hadfield.epub")

plugin.selected_feed = ""
plugin.selected_feed_label = ""
plugin.mirror_selected_sync_source = true
local old_volume_path = "/library/Insomniacs After School, Vol. 01 - Makoto Ojiro.epub"
local new_volume_path = "/library/Insomniacs After School, Vol. 1 - Makoto Ojiro.epub"
local old_volume = {
    book_id = "volume-1",
    title = "Insomniacs After School, Vol. 01",
    author = "Makoto Ojiro",
    genres = {},
}
local renamed_volume = {
    book_id = "volume-1",
    title = "Insomniacs After School, Vol. 1",
    author = "Makoto Ojiro",
    genres = {},
}
local identity_manifest = { version = 1, books = {} }
plugin:storeManifestEntry(identity_manifest, old_volume_path, old_volume)
identity_manifest.books[old_volume_path].refreshed_at = 1
fake_files[old_volume_path] = true

local original_load_manifest = plugin.loadManifest
local original_save_manifest = plugin.saveManifest
plugin.loadManifest = function() return identity_manifest end
plugin.saveManifest = function() return true end

local renamed_missing = assert(plugin:buildMissingBookQueue({
    { path = old_volume_path, filename = "Insomniacs After School, Vol. 01 - Makoto Ojiro.epub" },
}, { renamed_volume }))
assert(#renamed_missing == 0)

local renamed_refresh = assert(plugin:buildMetadataRefreshQueue({
    { path = old_volume_path, filename = "Insomniacs After School, Vol. 01 - Makoto Ojiro.epub" },
}, { renamed_volume }))
assert(#renamed_refresh == 1)
assert(renamed_refresh[1].local_path == old_volume_path)

local old_subtitle_path = "/library/The Murderbot Diaries All Systems Red - Martha Wells.epub"
local old_subtitle_title = {
    book_id = "subtitle-1",
    title = "The Murderbot Diaries: All Systems Red",
    author = "Martha Wells",
    genres = {},
}
local separated_subtitle = {
    book_id = "subtitle-1",
    title = "All Systems Red",
    subtitle = "The Murderbot Diaries",
    author = "Martha Wells",
    genres = {},
}
plugin:storeManifestEntry(identity_manifest, old_subtitle_path, old_subtitle_title)
fake_files[old_subtitle_path] = true
local subtitle_refresh = assert(plugin:buildMetadataRefreshQueue({
    { path = old_subtitle_path, filename = "The Murderbot Diaries All Systems Red - Martha Wells.epub" },
}, { separated_subtitle }))
assert(#subtitle_refresh == 1)
assert(subtitle_refresh[1].local_path == old_subtitle_path)

plugin:storeManifestEntry(identity_manifest, new_volume_path, renamed_volume)
identity_manifest.books[new_volume_path].refreshed_at = 2
fake_files[new_volume_path] = true
local duplicate_cleanup, duplicate_stats = plugin:buildMirrorCleanupQueue({
    { path = old_volume_path, filename = "Insomniacs After School, Vol. 01 - Makoto Ojiro.epub" },
    { path = new_volume_path, filename = "Insomniacs After School, Vol. 1 - Makoto Ojiro.epub" },
    { path = old_subtitle_path, filename = "The Murderbot Diaries All Systems Red - Martha Wells.epub" },
}, { renamed_volume, separated_subtitle }, identity_manifest)
assert(#duplicate_cleanup == 1)
assert(duplicate_cleanup[1].path == old_volume_path)
assert(duplicate_cleanup[1].reason == "duplicate")
assert(duplicate_stats.duplicate_candidates == 1)
assert(plugin:isLargeMirrorCleanup(duplicate_cleanup, 3) == false)
local large_cleanup = {}
for i = 1, 20 do large_cleanup[i] = { reason = "removed" } end
assert(plugin:isLargeMirrorCleanup(large_cleanup, 3000) == true)
assert(plugin:isLargeMirrorCleanup({ {}, {}, {}, {}, {} }, 10) == true)
assert(plugin:isLargeMirrorCleanup({ {}, {}, {}, {} }, 100) == false)

local removed_cbz_path = "/library/Manga/Removed series.cbz"
local removed_cbz = {
    book_id = "removed-cbz",
    title = "Removed series",
    author = "Manga Author",
    file_extension = "cbz",
    genres = {},
}
plugin:storeManifestEntry(identity_manifest, removed_cbz_path, removed_cbz)
fake_files[removed_cbz_path] = true
local existing_cbz = assert(plugin:buildMissingBookQueue({
    { path = removed_cbz_path, filename = "Manga/Removed series.cbz" },
}, { removed_cbz }))
assert(#existing_cbz == 0)

local old_epub_path = "/library/Manga/Changed format.epub"
local old_epub = {
    book_id = "changed-format",
    title = "Changed format",
    author = "Manga Author",
    file_extension = "epub",
    genres = {},
}
local changed_to_cbz = {
    book_id = "changed-format",
    title = "Changed format",
    author = "Manga Author",
    file_extension = "cbz",
    source_relative_path = "Manga/Changed format.epub",
    genres = {},
}
plugin:storeManifestEntry(identity_manifest, old_epub_path, old_epub)
fake_files[old_epub_path] = true
local changed_format_missing = assert(plugin:buildMissingBookQueue({
    { path = old_epub_path, filename = "Manga/Changed format.epub" },
}, { changed_to_cbz }))
assert(#changed_format_missing == 1)
assert(changed_format_missing[1] == changed_to_cbz)

local cbz_cleanup = plugin:buildMirrorCleanupQueue({
    { path = removed_cbz_path, filename = "Manga/Removed series.cbz" },
}, {}, identity_manifest)
assert(#cbz_cleanup == 1)
assert(cbz_cleanup[1].path == removed_cbz_path)
assert(cbz_cleanup[1].reason == "removed")

local trash_root = "/library/.library-sync-trash"
local new_batch = trash_root .. "/20260828-100000"
local old_batch = trash_root .. "/20260828-090000"
fake_dirs[trash_root] = true
fake_dirs[new_batch] = true
fake_dirs[old_batch] = true
fake_dirs[new_batch .. "/Fiction"] = true
fake_dirs[new_batch .. "/Manga"] = true
fake_dirs[old_batch .. "/Fiction"] = true
fake_dir_entries[trash_root] = { ".", "..", "20260828-090000", "20260828-100000" }
fake_dir_entries[new_batch] = { ".", "..", ".library-sync-restore.lua", "Fiction", "Manga" }
fake_dir_entries[old_batch] = { ".", "..", "Fiction" }
fake_dir_entries[new_batch .. "/Fiction"] = { ".", "..", "Min kamp 6.epub" }
fake_dir_entries[new_batch .. "/Manga"] = { ".", "..", "Existing.epub", "Restore.cbz" }
fake_dir_entries[old_batch .. "/Fiction"] = { ".", "..", "Min kamp 6.epub" }
fake_files[new_batch .. "/Fiction/Min kamp 6.epub"] = true
fake_files[new_batch .. "/Manga/Existing.epub"] = true
fake_files[new_batch .. "/Manga/Restore.cbz"] = true
fake_files[old_batch .. "/Fiction/Min kamp 6.epub"] = true
fake_files["/library/Manga/Existing.epub"] = true

local restore_queue, restore_stats, restore_err = plugin:buildMirrorRestoreQueue()
assert(restore_queue, tostring(restore_err))
assert(#restore_queue == 2)
assert(restore_queue[1].source == new_batch .. "/Fiction/Min kamp 6.epub")
assert(restore_queue[1].destination == "/library/Fiction/Min kamp 6.epub")
assert(restore_queue[2].source == new_batch .. "/Manga/Restore.cbz")
assert(restore_queue[2].destination == "/library/Manga/Restore.cbz")
assert(restore_stats.batches == 2)
assert(restore_stats.found == 4)
assert(restore_stats.conflicts == 1)
assert(restore_stats.older_backups == 1)

plugin.loadManifest = original_load_manifest
plugin.saveManifest = original_save_manifest

local separator = string.char(31)
local unchanged = {
    title = "Dune",
    author = "Frank Herbert",
    series = "Dune",
    series_index = "1",
    hardcover_id = "dune",
    hardcover_book_id = "99",
    description = "Arrakis",
    genres = { "Science Fiction" },
}
local previous_signature = table.concat({
    unchanged.title,
    unchanged.author,
    unchanged.series,
    unchanged.series_index,
    unchanged.hardcover_id,
    unchanged.hardcover_book_id,
    unchanged.description,
    unchanged.genres[1],
}, separator)
local matches, needs_migration = plugin:metadataSignatureMatches({ signature = previous_signature }, unchanged)
assert(matches == true)
assert(needs_migration == true)

print("provider contract tests passed")

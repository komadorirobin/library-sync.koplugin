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
assert(plugin:isLikelyBookDownloadLink({
    rel = "http://opds-spec.org/acquisition",
    href = "/api/v1/opds/42/download?fileId=10",
    type = "application/pdf",
}) == false)

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
local parsed_books = assert(plugin:fetchBooklistFromServer())
assert(#parsed_books == 1)
assert(parsed_books[1].book_id == "42")
assert(parsed_books[1].series == "Apollo")
assert(parsed_books[1].series_index == "2")
assert(parsed_books[1].download_url == "/api/v1/opds/42/download?fileId=9")

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

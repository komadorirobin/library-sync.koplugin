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
package.preload["json"] = function()
    return { decode = function(body) return decoded_json[body] end }
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
bookorbit.book_api.page_size = 2
bookorbit.author_api.page_size = 2
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
bookorbit.book_api.page_size = original_book_page_size
bookorbit.author_api.page_size = original_author_page_size

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

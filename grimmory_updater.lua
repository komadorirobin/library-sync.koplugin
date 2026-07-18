local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local logger = require("logger")
local _ = require("gettext")

local GITHUB_OWNER = "komadorirobin"
local GITHUB_REPO = "library-sync.koplugin"
local API_URL = string.format(
    "https://api.github.com/repos/%s/%s/releases/latest",
    GITHUB_OWNER,
    GITHUB_REPO
)

local Updater = {}

local PLUGIN_DIR = (debug.getinfo(1, "S").source or ""):match("^@(.+)/[^/]+$")
    or "/storage/emulated/0/koreader/plugins/library-sync.koplugin"
local PLUGIN_DIR_NAME = PLUGIN_DIR:match("([^/]+)$") or "library-sync.koplugin"
local PREFERRED_ASSET_NAME = PLUGIN_DIR_NAME == "grimmory-sync.koplugin"
    and "grimmory-sync.koplugin.zip"
    or "library-sync.koplugin.zip"
local ASSET_NAMES = {
    PREFERRED_ASSET_NAME,
    "library-sync.koplugin.zip",
    "grimmory-sync.koplugin.zip",
}

local function currentVersion()
    local ok, meta = pcall(dofile, PLUGIN_DIR .. "/_meta.lua")
    if ok and type(meta) == "table" and meta.version then
        return meta.version
    end

    local req_ok, req_meta = pcall(require, "_meta")
    return (req_ok and req_meta and req_meta.version) or "0.0.0"
end

local function versionParts(version)
    version = (version or ""):match("^v?(.-)[-+]") or (version or ""):match("^v?(.+)$") or ""
    local parts = {}
    for number in (version .. "."):gmatch("(%d+)%.") do
        parts[#parts + 1] = tonumber(number) or 0
    end
    while #parts < 3 do
        parts[#parts + 1] = 0
    end
    return parts
end

local function versionGreaterThan(a, b)
    local pa, pb = versionParts(a), versionParts(b)
    for i = 1, 3 do
        if pa[i] > pb[i] then return true end
        if pa[i] < pb[i] then return false end
    end
    return false
end

local function toast(message, timeout)
    local widget = InfoMessage:new{
        text = message,
        timeout = timeout or 4,
    }
    UIManager:show(widget)
    return widget
end

local function closeWidget(widget)
    if widget then
        UIManager:close(widget)
    end
end

local function httpRequest(url, sink, accept_header)
    local ok_socketutil, socketutil = pcall(require, "socketutil")
    local http = require("socket/http")
    local socket = require("socket")

    if ok_socketutil then
        socketutil:set_timeout(
            socketutil.LARGE_BLOCK_TIMEOUT,
            socketutil.LARGE_TOTAL_TIMEOUT
        )
    end

    local code, headers, status = socket.skip(1, http.request({
        url = url,
        method = "GET",
        headers = {
            ["User-Agent"] = "KOReader-LibrarySync-Updater/1.0",
            ["Accept"] = accept_header or "*/*",
        },
        sink = sink,
        redirect = true,
    }))

    if ok_socketutil then
        socketutil:reset_timeout()
    end

    if ok_socketutil and (
        code == socketutil.TIMEOUT_CODE or
        code == socketutil.SSL_HANDSHAKE_CODE or
        code == socketutil.SINK_TIMEOUT_CODE
    ) then
        return nil, "timeout (" .. tostring(code) .. ")"
    end

    if headers == nil then
        return nil, "network error (" .. tostring(code or status) .. ")"
    end

    if code == 200 then
        return true
    end

    return nil, "HTTP " .. tostring(code)
end

local function httpGet(url)
    local ltn12 = require("ltn12")
    local chunks = {}
    local ok, err = httpRequest(
        url,
        ltn12.sink.table(chunks),
        "application/vnd.github.v3+json"
    )
    if not ok then
        return nil, err
    end
    return table.concat(chunks), nil
end

local function httpGetToFile(url, path)
    local ltn12 = require("ltn12")
    local file, open_err = io.open(path, "wb")
    if not file then
        return nil, "cannot create file: " .. tostring(open_err)
    end

    local ok, err = httpRequest(url, ltn12.sink.file(file), "*/*")
    if not ok then
        pcall(os.remove, path)
        return nil, err
    end

    local attr_ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if attr_ok and lfs then
        local attr = lfs.attributes(path)
        if not attr or attr.size == 0 then
            pcall(os.remove, path)
            return nil, "downloaded file is empty"
        end
    end

    return true, nil
end

local function decodeJsonString(value)
    if not value then return nil end
    value = value:gsub("\\n", "\n")
        :gsub("\\r", "")
        :gsub('\\"', '"')
        :gsub("\\/", "/")
        :gsub("\\\\", "\\")
    return value
end

local function wantedAssetName(name)
    for _, asset_name in ipairs(ASSET_NAMES) do
        if name == asset_name then
            return true
        end
    end
    return false
end

local function cleanReleaseNotes(notes)
    if not notes or notes == "" then return nil end
    notes = notes:gsub("#+%s*", "")
        :gsub("%*%*(.-)%*%*", "%1")
        :gsub("`(.-)`", "%1")
        :gsub("\r\n", "\n")
        :gsub("\r", "\n")
        :match("^%s*(.-)%s*$")
    if #notes > 600 then
        notes = notes:sub(1, 597) .. "..."
    end
    return notes ~= "" and notes or nil
end

local function parseRelease(body)
    local ok_json, json = pcall(require, "json")
    if ok_json then
        local ok_decode, data = pcall(json.decode, body)
        if ok_decode and type(data) == "table" then
            local tag = data.tag_name
            if not tag or tag == "" then
                return nil, "tag_name missing from API response"
            end

            local download_url
            for _, asset in ipairs(data.assets or {}) do
                if asset.name == PREFERRED_ASSET_NAME then
                    download_url = asset.browser_download_url
                    break
                end
                if not download_url and wantedAssetName(asset.name) then
                    download_url = asset.browser_download_url
                end
                if not download_url and type(asset.name) == "string" and asset.name:match("%.zip$") then
                    download_url = asset.browser_download_url
                end
            end

            return {
                version = tag:match("^v?(.*)$"),
                download_url = download_url,
                notes = cleanReleaseNotes(data.body),
                html_url = data.html_url,
            }
        end
    end

    local tag = body:match('"tag_name"%s*:%s*"([^"]+)"')
    if not tag then
        return nil, "could not parse tag_name"
    end

    local download_url
    for _, asset_name in ipairs(ASSET_NAMES) do
        local asset_pattern = '"browser_download_url"%s*:%s*"([^"]*'
            .. asset_name:gsub("%.", "%%.") .. '[^"]*)"'
        download_url = body:match(asset_pattern)
        if download_url then
            break
        end
    end
    if not download_url then
        download_url = body:match('"browser_download_url"%s*:%s*"([^"]+%.zip)"')
    end

    local notes = decodeJsonString(body:match('"body"%s*:%s*"(.-)"%s*[,}]'))
    return {
        version = tag:match("^v?(.*)$"),
        download_url = download_url,
        notes = cleanReleaseNotes(notes),
        html_url = decodeJsonString(body:match('"html_url"%s*:%s*"([^"]+)"')),
    }
end

local function fetchLatestRelease()
    local body, err = httpGet(API_URL)
    if not body then
        return nil, err
    end

    local release, parse_err = parseRelease(body)
    if not release then
        return nil, "parse error: " .. tostring(parse_err)
    end

    return release, nil
end

local function tmpZipPath()
    local candidates = {}

    local ok_datastorage, datastorage = pcall(require, "datastorage")
    if ok_datastorage and datastorage then
        local settings_dir = datastorage:getSettingsDir()
        if settings_dir then
            candidates[#candidates + 1] = settings_dir .. "/library_sync_update.zip"
        end
    end

    candidates[#candidates + 1] = "/tmp/library_sync_update.zip"
    candidates[#candidates + 1] = PLUGIN_DIR .. "/library_sync_update.zip"

    for _, path in ipairs(candidates) do
        local file = io.open(path, "wb")
        if file then
            file:close()
            os.remove(path)
            return path
        end
    end

    return PLUGIN_DIR .. "/library_sync_update.zip"
end

local function unzip(zip_path, destination)
    local result = os.execute(string.format("unzip -o -q %q -d %q", zip_path, destination))
    if result ~= 0 and result ~= true then
        return nil, "unzip failed (exit " .. tostring(result) .. ")"
    end
    return true, nil
end

local function installUpdate(download_url, version)
    local zip_path = tmpZipPath()
    local parent_dir = PLUGIN_DIR:match("^(.+)/[^/]+$") or PLUGIN_DIR
    local progress = toast(string.format(_("Downloading Library Sync %s…"), version), 120)
    local ok_trapper, Trapper = pcall(require, "ui/trapper")

    local function doInstall()
        local download_ok, download_err = httpGetToFile(download_url, zip_path)
        if not download_ok then
            return { success = false, stage = "download", err = download_err }
        end

        local unzip_ok, unzip_err = unzip(zip_path, parent_dir)
        pcall(os.remove, zip_path)
        if not unzip_ok then
            return { success = false, stage = "unzip", err = unzip_err }
        end

        return { success = true }
    end

    local function handleResult(result)
        closeWidget(progress)
        if not result or not result.success then
            local stage = result and result.stage or "unknown"
            local err = result and result.err or "unknown error"
            logger.err("[GrimmorySync] OTA update failed:", stage, err)
            toast(
                stage == "download"
                    and (_("Download error: ") .. tostring(err))
                    or (_("Extraction error: ") .. tostring(err)),
                6
            )
            return
        end

        UIManager:show(ConfirmBox:new{
            text = string.format(
                _("Library Sync %s installed.\n\nRestart KOReader to apply the update?"),
                version
            ),
            ok_text = _("Restart"),
            cancel_text = _("Later"),
            ok_callback = function()
                UIManager:restartKOReader()
            end,
        })
    end

    if ok_trapper and Trapper and Trapper.dismissableRunInSubprocess then
        local completed, result = Trapper:dismissableRunInSubprocess(
            doInstall,
            progress,
            function(res)
                handleResult(res)
            end
        )

        if completed and result then
            UIManager:scheduleIn(0.2, function()
                handleResult(result)
            end)
        elseif completed == false then
            closeWidget(progress)
            pcall(os.remove, zip_path)
            toast(_("Update cancelled."))
        end
    else
        UIManager:scheduleIn(0.3, function()
            handleResult(doInstall())
        end)
    end
end

local function showUpdateDialog(release, current)
    local latest = release.version
    if not versionGreaterThan(latest, current) then
        toast(string.format(_("Library Sync is up to date (%s)."), current))
        return
    end

    local text = string.format(
        _("Library Sync %s is available.\nYou have %s."),
        latest,
        current
    )
    if release.notes then
        text = text .. "\n\n" .. _("What's new:") .. "\n" .. release.notes
    end

    if not release.download_url or release.download_url == "" then
        UIManager:show(ConfirmBox:new{
            text = text .. "\n\n" .. _("No release ZIP found."),
            ok_text = _("OK"),
        })
        return
    end

    UIManager:show(ConfirmBox:new{
        text = text .. "\n\n" .. _("Download and install now?"),
        ok_text = _("Download and install"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            installUpdate(release.download_url, latest)
        end,
    })
end

function Updater.checkForUpdates()
    local current = currentVersion()
    local ok_network, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_network and NetworkMgr and NetworkMgr.runWhenOnline then
        NetworkMgr:runWhenOnline(function()
            Updater._checkNow(current)
        end)
        return
    end

    Updater._checkNow(current)
end

function Updater._checkNow(current)
    local checking = toast(_("Checking for updates…"), 15)
    local ok_trapper, Trapper = pcall(require, "ui/trapper")

    local function doCheck()
        local release, err = fetchLatestRelease()
        if not release then
            return { error = err }
        end
        return release
    end

    local function handleResult(release)
        closeWidget(checking)
        if not release then
            toast(_("Error checking for updates."), 5)
            return
        end
        if release.error then
            logger.err("[GrimmorySync] OTA update check failed:", release.error)
            toast(_("Error checking for updates: ") .. tostring(release.error), 6)
            return
        end

        showUpdateDialog(release, current)
    end

    if ok_trapper and Trapper and Trapper.dismissableRunInSubprocess then
        local completed, result = Trapper:dismissableRunInSubprocess(
            doCheck,
            checking,
            function(res)
                handleResult(res)
            end
        )

        if completed and result then
            UIManager:scheduleIn(0.2, function()
                handleResult(result)
            end)
        elseif completed == false then
            closeWidget(checking)
            toast(_("Update check cancelled."))
        end
    else
        UIManager:scheduleIn(0.3, function()
            handleResult(doCheck())
        end)
    end
end

return Updater

-- SPDX-FileCopyrightText: 2026 Contributors to Chatterino <https://chatterino.com>
-- SPDX-License-Identifier: MIT

-- Lightshot preview
--
-- Renders prnt.sc screenshots inline when a message contains a `ls:CODE`
-- token. The image is only added locally, other users still see the raw text.
--
-- Example: `ls:rnfcsk` -> https://prnt.sc/rnfcsk

local lightshot = require("lightshot")

-- Images are scaled down to fit inside this box. Change these values if you
-- want bigger or smaller previews.
local MAX_WIDTH = 400
local MAX_HEIGHT = 400

-- How many `ls:CODE` tokens are rendered per message.
local MAX_CODES_PER_MESSAGE = 2

-- Interval used to discover channels that were opened after the plugin was
-- loaded. Chatterino does not expose a global "channel opened" event.
local SCAN_INTERVAL_MS = 2000

local REQUEST_TIMEOUT_MS = 10000
local PAGE_TTL_MS = 24 * 60 * 60 * 1000
local MISS_TTL_MS = 5 * 60 * 1000
local DEFER_MS = 10

local HANDLED_LIMIT = 5000
local CACHE_LIMIT = 500

local BROWSER_USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) "
    .. "AppleWebKit/537.36 (KHTML, like Gecko) "
    .. "Chrome/131.0.0.0 Safari/537.36"

---@type table<string, { url: string|nil, expires: integer }>
local page_cache = {}
---@type table<string, { width: integer, height: integer }>
local dim_cache = {}
---@type table<string, fun(url: string|nil): nil[]>
local page_inflight = {}
---@type table<string, fun(width: integer|nil, height: integer|nil): nil[]>
local dim_inflight = {}
---@type table<string, boolean>
local handled = {}
---@type string[]
local handled_order = {}
---@type table<string, { channel: c2.Channel, handle: c2.ConnectionHandle }>
local hooked = {}
local stats = {
    detected = 0,
    resolved = 0,
    missed = 0,
    replaced = 0,
    replaceFailed = 0,
}

---@return integer
local function now_ms()
    local ok, value = pcall(function()
        return c2.DateTime.current_utc():to_unix_milliseconds()
    end)
    if ok and type(value) == "number" then
        return value
    end
    return 0
end

---@param callback fun(...): nil
---@return fun(...): nil
local function safe(callback)
    return function(...)
        local ok, err = pcall(callback, ...)
        if not ok then
            c2.log(c2.LogLevel.Warning, "[lightshot] callback error:",
                tostring(err))
        end
    end
end

---@param cache table
---@param key string
---@param value table
local function cache_set(cache, key, value)
    if cache[key] == nil then
        local count = 0
        for _ in pairs(cache) do
            count = count + 1
        end
        if count >= CACHE_LIMIT then
            for existing in pairs(cache) do
                cache[existing] = nil
            end
        end
    end
    cache[key] = value
end

---@param key string
local function remember_handled(key)
    handled[key] = true
    handled_order[#handled_order + 1] = key

    if #handled_order > HANDLED_LIMIT then
        local oldest = table.remove(handled_order, 1)
        if oldest then
            handled[oldest] = nil
        end
    end
end

---@param channel c2.Channel
---@return string|nil
local function channel_key(channel)
    local ok, name = pcall(function()
        return channel:get_name()
    end)
    if not ok or type(name) ~= "string" then
        return nil
    end

    local twitch_ok, is_twitch = pcall(function()
        return channel:is_twitch_channel()
    end)
    local platform = (twitch_ok and is_twitch) and "twitch:" or "other:"
    return platform .. name:lower()
end

---@param url string
---@param headers table<string, string>|nil
---@param on_success fun(response: c2.HTTPResponse): nil
---@param on_error (fun(response: c2.HTTPResponse): nil)|nil
local function http_get(url, headers, on_success, on_error)
    local request = c2.HTTPRequest.create(c2.HTTPMethod.Get, url)
    request:set_timeout(REQUEST_TIMEOUT_MS)

    if headers then
        for name, value in pairs(headers) do
            request:set_header(name, value)
        end
    end

    request:on_success(safe(on_success))
    request:on_error(safe(function(response)
        if on_error then
            on_error(response)
            return
        end
        c2.log(c2.LogLevel.Debug, "[lightshot] request failed:", url,
            tostring(response:status()), tostring(response:error()))
    end))
    request:execute()
end

---@param url string
---@return boolean
local function is_lightshot_image(url)
    if type(url) ~= "string" then
        return false
    end
    -- Old screenshots live on image.prntscr.com, newer ones on
    -- img.lightshot.app. Invalid ids point at a static placeholder on
    -- st.prntscr.com, which must not be treated as a screenshot.
    return url:match("^https://image%.prntscr%.com/") ~= nil
        or url:match("^https://img%.lightshot%.app/") ~= nil
end

--- Resolves the direct image URL of a prnt.sc page.
---@param code string
---@param callback fun(url: string|nil): nil
local function fetch_page(code, callback)
    local cached = page_cache[code]
    if cached and cached.expires > now_ms() then
        callback(cached.url)
        return
    end

    local waiting = page_inflight[code]
    if waiting then
        waiting[#waiting + 1] = callback
        return
    end
    page_inflight[code] = { callback }

    local function finish(url)
        local callbacks = page_inflight[code]
        page_inflight[code] = nil
        if not callbacks then
            return
        end
        for _, queued in ipairs(callbacks) do
            queued(url)
        end
    end

    http_get("https://prnt.sc/" .. code, {
        ["User-Agent"] = BROWSER_USER_AGENT,
        ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ["Accept-Language"] = "en-US,en;q=0.9",
        ["Referer"] = "https://prnt.sc/",
    }, function(response)
        local status = response:status()
        if status ~= 200 then
            -- Transient errors (Cloudflare challenges, rate limits, ...) are
            -- not cached so the next message retries.
            c2.log(c2.LogLevel.Debug, "[lightshot] page returned", tostring(status),
                "for", code)
            finish(nil)
            return
        end

        local url = lightshot.extract_image_url(response:data())
        if not is_lightshot_image(url) then
            c2.log(c2.LogLevel.Debug, "[lightshot] no screenshot found for", code)
            stats.missed = stats.missed + 1
            cache_set(page_cache, code, { expires = now_ms() + MISS_TTL_MS })
            finish(nil)
            return
        end

        c2.log(c2.LogLevel.Debug, "[lightshot] image url for", code, ":", url)
        stats.resolved = stats.resolved + 1
        cache_set(page_cache, code, {
            url = url,
            expires = now_ms() + PAGE_TTL_MS,
        })
        finish(url)
    end, function(response)
        c2.log(c2.LogLevel.Debug, "[lightshot] page request failed:", code,
            tostring(response:status()), tostring(response:error()))
        finish(nil)
    end)
end

--- Reads the image size from the first chunk of the image.
---@param url string
---@param callback fun(width: integer|nil, height: integer|nil): nil
local function fetch_dimensions(url, callback)
    local cached = dim_cache[url]
    if cached then
        callback(cached.width, cached.height)
        return
    end

    local waiting = dim_inflight[url]
    if waiting then
        waiting[#waiting + 1] = callback
        return
    end
    dim_inflight[url] = { callback }

    local function finish(width, height)
        local callbacks = dim_inflight[url]
        dim_inflight[url] = nil
        if not callbacks then
            return
        end
        for _, queued in ipairs(callbacks) do
            queued(width, height)
        end
    end

    http_get(url, {
        ["User-Agent"] = BROWSER_USER_AGENT,
        ["Range"] = "bytes=0-65535",
    }, function(response)
        local width, height = lightshot.image_dimensions(response:data())
        c2.log(c2.LogLevel.Debug, "[lightshot] dimensions for", url, ":",
            tostring(width), "x", tostring(height))
        if width and height then
            cache_set(dim_cache, url, { width = width, height = height })
        end
        finish(width, height)
    end, function()
        finish(nil, nil)
    end)
end

---@alias LightshotImage { code: string, url: string, width: integer|nil, height: integer|nil }

--- Resolves all codes of a message, preserving their order.
---@param codes string[]
---@param callback fun(images: LightshotImage[]): nil
local function resolve_codes(codes, callback)
    if #codes == 0 then
        callback({})
        return
    end

    local results = {}
    local remaining = #codes

    local function finish()
        remaining = remaining - 1
        if remaining > 0 then
            return
        end

        local resolved = {}
        for index = 1, #codes do
            if results[index] then
                resolved[#resolved + 1] = results[index]
            end
        end
        callback(resolved)
    end

    for index, code in ipairs(codes) do
        fetch_page(code, function(url)
            if not url then
                finish()
                return
            end

            fetch_dimensions(url, function(width, height)
                results[index] = {
                    code = code,
                    url = url,
                    width = width,
                    height = height,
                }
                finish()
            end)
        end)
    end
end

---@param width integer|nil
---@param height integer|nil
---@param max_width integer|nil
---@param max_height integer|nil
local function scale_for(width, height, max_width, max_height)
    return lightshot.scale_for(width, height, max_width, max_height)
end

---@param image LightshotImage
---@param flags c2.MessageElementFlag
---@return table
local function image_element(image, flags)
    local scale, expected_size = scale_for(image.width, image.height, MAX_WIDTH,
        MAX_HEIGHT)

    return {
        type = "image",
        image = c2.Image.from_url(image.url, scale, expected_size),
        flags = flags,
        trailing_space = false,
        tooltip = "Lightshot " .. image.code,
        link = {
            type = c2.LinkType.Url,
            value = "https://prnt.sc/" .. image.code,
        },
    }
end

---@param channel c2.Channel
---@param message c2.Message
---@param images LightshotImage[]
local function build_replacement(channel, message, images)
    local message_id = tostring(message.id or "")
    local found_before = false
    pcall(function()
        found_before = channel:find_message_by_id(message_id) ~= nil
    end)
    c2.log(c2.LogLevel.Debug, "[lightshot] replacing", message_id, "found:",
        tostring(found_before), "images:", tostring(#images))

    local replacement = message:clone()
    for _, image in ipairs(images) do
        replacement:append_element({
            type = "linebreak",
            flags = c2.MessageElementFlag.AlwaysShow,
        })
        replacement:append_element(
            image_element(image, c2.MessageElementFlag.AlwaysShow))
    end

    channel:replace_message(message, replacement)

    local found_after = false
    local image_elements = 0
    pcall(function()
        local after = channel:find_message_by_id(message_id)
        if not after then
            return
        end
        found_after = true
        for _, element in ipairs(after:elements()) do
            if element.type == "image" then
                image_elements = image_elements + 1
            end
        end
    end)
    c2.log(c2.LogLevel.Debug, "[lightshot] replaced", message_id, "found:",
        tostring(found_after), "image elements:", tostring(image_elements))

    if found_after and image_elements > 0 then
        stats.replaced = stats.replaced + 1
    else
        stats.replaceFailed = stats.replaceFailed + 1
    end
end

---@param message c2.Message
---@return boolean
local function has_image_element(message)
    local ok, elements = pcall(function()
        return message:elements()
    end)
    if not ok or not elements then
        return false
    end

    local found = false
    pcall(function()
        for _, element in ipairs(elements) do
            if element.type == "image" then
                found = true
                break
            end
        end
    end)
    return found
end

---@param channel c2.Channel
---@param message c2.Message
local function handle_message(channel, message)
    if not message then
        return
    end

    local text = message.message_text
    if type(text) ~= "string" or not text:lower():find("ls:", 1, true) then
        return
    end

    -- Don't stack a second preview on top of a message that was already
    -- rewritten (for example after reloading the plugin).
    if has_image_element(message) then
        return
    end

    local codes = lightshot.extract_codes(text, MAX_CODES_PER_MESSAGE)
    if #codes == 0 then
        return
    end

    local key = channel_key(channel)
    if not key then
        return
    end

    local message_id = tostring(message.id or "")
    local dedupe_key = key .. "|" .. message_id
    if message_id == "" then
        dedupe_key = dedupe_key .. "|" .. tostring(message.timestamp) .. "|"
            .. text
    end
    if handled[dedupe_key] then
        return
    end
    remember_handled(dedupe_key)

    c2.log(c2.LogLevel.Debug, "[lightshot] resolving", #codes, "code(s) in",
        key, ":", table.concat(codes, ","))
    stats.detected = stats.detected + 1

    resolve_codes(codes, function(images)
        if #images == 0 then
            return
        end

        -- Defer: when everything was cached this callback can run
        -- synchronously inside on_message_appended, where replacing the
        -- message would hit Chatterino's recursion guard.
        c2.later(safe(function()
            local valid_ok, valid = pcall(function()
                return channel:is_valid()
            end)
            if not valid_ok or not valid then
                return
            end
            build_replacement(channel, message, images)
        end), DEFER_MS)
    end)
end

---@param channel c2.Channel
local function backfill(channel)
    local ok, messages = pcall(function()
        return channel:message_snapshot(30)
    end)
    if not ok or not messages then
        return
    end

    pcall(function()
        for _, message in ipairs(messages) do
            handle_message(channel, message)
        end
    end)
end

---@param channel c2.Channel
local function hook_channel(channel)
    local key = channel_key(channel)
    if not key or hooked[key] then
        return
    end

    local ok, handle = pcall(function()
        return channel:on_message_appended(safe(function(message)
            handle_message(channel, message)
        end))
    end)
    if not ok then
        c2.log(c2.LogLevel.Warning, "[lightshot] could not hook", key,
            tostring(handle))
        return
    end

    hooked[key] = {
        channel = channel,
        handle = handle,
    }

    backfill(channel)
end

local function scan_channels()
    for key, entry in pairs(hooked) do
        local ok, valid = pcall(function()
            return entry.channel:is_valid()
        end)
        if not ok or not valid then
            hooked[key] = nil
        end
    end

    local ok, err = pcall(function()
        for _, window in ipairs(c2.windows:all()) do
            local notebook = window.notebook
            for index = 0, notebook.page_count - 1 do
                local page = notebook:page_at(index)
                if page then
                    for _, split in ipairs(page:splits()) do
                        if split.channel then
                            hook_channel(split.channel)
                        end
                    end
                end
            end
        end
    end)
    if not ok then
        c2.log(c2.LogLevel.Debug, "[lightshot] channel scan failed:",
            tostring(err))
    end

    c2.later(scan_channels, SCAN_INTERVAL_MS)
end

---@param channel c2.Channel
---@param text string
local function system_message(channel, text)
    pcall(function()
        channel:add_system_message(text)
    end)
end

---@param channel c2.Channel
---@param images LightshotImage[]
local function add_preview_message(channel, images)
    if #images == 0 then
        return
    end

    local first = images[1]
    local elements = {
        {
            type = "text",
            text = "Lightshot: https://prnt.sc/" .. first.code,
        },
    }

    for _, image in ipairs(images) do
        elements[#elements + 1] = {
            type = "linebreak",
            flags = c2.MessageElementFlag.AlwaysShow,
        }
        elements[#elements + 1] = image_element(image,
            c2.MessageElementFlag.AlwaysShow)
    end

    channel:add_message(c2.Message.new({
        id = "lightshot-command-" .. tostring(now_ms()) .. "-" .. first.code,
        elements = elements,
    }))
end

---@param ctx CommandContext
local function command_status(ctx)
    local channel = ctx.channel
    local key = channel_key(channel) or "?"

    local hooked_count = 0
    for _ in pairs(hooked) do
        hooked_count = hooked_count + 1
    end

    system_message(channel, string.format(
        "[lightshot] hooked channels: %d, this: %s", hooked_count, key))
    system_message(channel, string.format(
        "[lightshot] detected=%d resolved=%d missed=%d replaced=%d failed=%d",
        stats.detected, stats.resolved, stats.missed, stats.replaced,
        stats.replaceFailed))

    local ok, messages = pcall(function()
        return channel:message_snapshot(50)
    end)
    if not ok or not messages then
        return
    end

    local hits = 0
    local with_images = 0
    pcall(function()
        for _, message in ipairs(messages) do
            local text = message.message_text or ""
            if text:lower():find("ls:", 1, true) then
                hits = hits + 1
                if has_image_element(message) then
                    with_images = with_images + 1
                end
            end
        end
    end)

    system_message(channel, string.format(
        "[lightshot] last 50 messages: %d with ls:, %d with an image", hits,
        with_images))
end

---@param ctx CommandContext
local function command_lightshot(ctx)
    local argument = ctx.words[2]
    if not argument then
        system_message(ctx.channel, "Usage: /lightshot <code> (or /lightshot https://prnt.sc/code)")
        return
    end

    local code = argument:match("prnt%.sc/([%w]+)") or argument:match("^([%w]+)$")
    if not code then
        system_message(ctx.channel, "Invalid Lightshot code: " .. argument)
        return
    end

    system_message(ctx.channel, "Loading Lightshot " .. code .. "...")

    resolve_codes({ code }, function(images)
        c2.later(safe(function()
            if #images == 0 then
                system_message(ctx.channel, "Could not find a Lightshot image for " .. code)
                return
            end
            if not ctx.channel:is_valid() then
                return
            end
            add_preview_message(ctx.channel, images)
        end), DEFER_MS)
    end)
end

for _, name in ipairs({ "/lightshot", "/ls", "/prnt" }) do
    if not c2.register_command(name, command_lightshot) then
        c2.log(c2.LogLevel.Debug, "[lightshot] command already registered:", name)
    end
end

if not c2.register_command("/lightshotstatus", command_status) then
    c2.log(c2.LogLevel.Debug, "[lightshot] /lightshotstatus already registered")
end

c2.log(c2.LogLevel.Debug, "[lightshot] loaded")
scan_channels()

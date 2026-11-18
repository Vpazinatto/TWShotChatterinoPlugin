-- SPDX-FileCopyrightText: 2026 Contributors to Chatterino <https://chatterino.com>
-- SPDX-License-Identifier: MIT

-- Pure helper functions for the Lightshot preview plugin.
--
-- Nothing in this file touches the `c2` API. This keeps the parsing logic
-- testable without starting Chatterino.

local M = {}

--- Codes shorter than this are ignored to avoid false positives (`ls:ab`).
--- Real Lightshot codes are 6 or 12 characters long, but shorter ids are
--- accepted so the `/lightshot` fallback and older links keep working.
M.MIN_CODE_LENGTH = 3
--- The longest code Lightshot currently generates is 12 characters, but
--- leave some room for future changes.
M.MAX_CODE_LENGTH = 16
--- Used when the dimensions of an image could not be determined.
M.DEFAULT_SCALE = 0.25

--- Strips punctuation that users commonly put around a token, such as
--- parentheses or a trailing comma.
---@param token string
---@return string
local function trim_token(token)
    local trimmed = token:gsub("^[%(%[%{<\"'`]+", "")
    trimmed = trimmed:gsub("[%)%]%}>\"'`,;:%.!%?]+$", "")
    return trimmed
end

--- Finds `ls:CODE` tokens in a message.
---
--- The returned codes preserve their original casing, because prnt.sc codes
--- are case-sensitive.
---@param text string
---@param limit integer|nil Maximum number of codes to return
---@return string[]
function M.extract_codes(text, limit)
    local codes = {}
    local seen = {}

    if type(text) ~= "string" then
        return codes
    end

    for raw_token in text:gmatch("%S+") do
        local token = trim_token(raw_token)
        if token:sub(1, 3):lower() == "ls:" then
            local code = token:sub(4):match("^([%w]+)$")
            if code then
                local length = #code
                if length >= M.MIN_CODE_LENGTH and length <= M.MAX_CODE_LENGTH
                    and not seen[code] then
                    seen[code] = true
                    codes[#codes + 1] = code
                    if limit and #codes >= limit then
                        return codes
                    end
                end
            end
        end
    end

    return codes
end

---@param html string
---@param attribute string
---@param value string
---@return string|nil
local function find_meta_content(html, attribute, value)
    local pattern = "<meta[^>]-" .. attribute .. '="' .. value
        .. '"[^>]-content="([^"]+)"'
    local content = html:match(pattern)
    if content then
        return content
    end

    pattern = '<meta[^>]-content="([^"]+)"[^>]-' .. attribute .. '="' .. value
        .. '"'
    return html:match(pattern)
end

--- Extracts the direct image URL from a prnt.sc page.
---@param html string
---@return string|nil
function M.extract_image_url(html)
    if type(html) ~= "string" then
        return nil
    end

    local url = find_meta_content(html, "property", "og:image")
        or find_meta_content(html, "name", "twitter:image:src")
    if not url then
        return nil
    end

    url = url:gsub("&amp;", "&")
    if url:sub(1, 2) == "//" then
        url = "https:" .. url
    end
    return url
end

---@param data string
---@param offset integer
---@return integer|nil
local function be16(data, offset)
    local a, b = data:byte(offset, offset + 1)
    if not a or not b then
        return nil
    end
    return a * 256 + b
end

---@param data string
---@param offset integer
---@return integer|nil
local function be32(data, offset)
    local a, b, c, d = data:byte(offset, offset + 3)
    if not a or not b or not c or not d then
        return nil
    end
    return ((a * 256 + b) * 256 + c) * 256 + d
end

---@param data string
---@param offset integer
---@return integer|nil
local function le16(data, offset)
    local a, b = data:byte(offset, offset + 1)
    if not a or not b then
        return nil
    end
    return a + b * 256
end

---@param data string
---@return integer|nil width
---@return integer|nil height
local function png_dimensions(data)
    if #data < 24 or data:sub(13, 16) ~= "IHDR" then
        return nil
    end
    local width = be32(data, 17)
    local height = be32(data, 21)
    if not width or not height or width == 0 or height == 0 then
        return nil
    end
    return width, height
end

---@param data string
---@return integer|nil width
---@return integer|nil height
local function gif_dimensions(data)
    if #data < 10 then
        return nil
    end
    local width = le16(data, 7)
    local height = le16(data, 9)
    if not width or not height or width == 0 or height == 0 then
        return nil
    end
    return width, height
end

---@param data string
---@return integer|nil width
---@return integer|nil height
local function jpeg_dimensions(data)
    local length = #data
    local index = 3

    while index + 3 <= length do
        if data:byte(index) ~= 0xFF then
            index = index + 1
        else
            local marker = data:byte(index + 1)
            if marker == 0xFF then
                index = index + 1
            elseif marker == 0xD8 or marker == 0x01
                or (marker >= 0xD0 and marker <= 0xD7) then
                index = index + 2
            elseif marker == 0xDA or marker == 0xD9 then
                -- Start of scan / end of image: no size information ahead.
                return nil
            else
                local segment_length = be16(data, index + 2)
                if not segment_length or segment_length < 2 then
                    return nil
                end

                local is_sof = marker >= 0xC0 and marker <= 0xCF
                    and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC
                if is_sof then
                    local height = be16(data, index + 5)
                    local width = be16(data, index + 7)
                    if width and height and width > 0 and height > 0 then
                        return width, height
                    end
                end

                index = index + 2 + segment_length
            end
        end
    end

    return nil
end

--- Determines the pixel size of a PNG, GIF, or JPEG image from its header.
---
--- Only the first bytes of the file are needed, so callers can use a HTTP
--- range request instead of downloading the whole screenshot.
---@param data string
---@return integer|nil width
---@return integer|nil height
function M.image_dimensions(data)
    if type(data) ~= "string" or #data < 10 then
        return nil
    end

    if data:sub(1, 8) == "\137PNG\r\n\26\n" then
        return png_dimensions(data)
    end

    local signature = data:sub(1, 6)
    if signature == "GIF87a" or signature == "GIF89a" then
        return gif_dimensions(data)
    end

    if data:byte(1) == 0xFF and data:byte(2) == 0xD8 then
        return jpeg_dimensions(data)
    end

    return nil
end

--- Calculates the scale at which an image fits within the given bounds.
---@param width integer|nil
---@param height integer|nil
---@param max_width integer|nil
---@param max_height integer|nil
---@return number scale
---@return integer[]|nil expected_size
function M.scale_for(width, height, max_width, max_height)
    if not width or not height or width <= 0 or height <= 0 then
        return M.DEFAULT_SCALE, nil
    end

    local scale = 1
    if max_width and width > max_width then
        scale = max_width / width
    end
    if max_height and height * scale > max_height then
        scale = max_height / height
    end

    return scale, { width, height }
end

return M

-- Checked WeRead shards: integrity validation, sparse unscrambling and host Base64.
local Crypto = require("welite.lib.crypto")
local M = {}

local function checked_body(response_text)
    if not response_text or #response_text <= 32 then
        return ""
    end
    local expected = response_text:sub(1, 32)
    local body = response_text:sub(33)
    local actual = Crypto.md5_hex(body):upper()
    if actual ~= expected then
        error("Shard MD5 mismatch")
    end
    return body
end

local function base64_decode(data)
    data = data:gsub("-", "+"):gsub("_", "/"):gsub("[^%w+/=]", "")
    local pad = #data % 4
    if pad > 0 then data = data .. string.rep("=", 4 - pad) end
    -- LuaSocket ships with KOReader. Decode in C without expanding to bit strings.
    return require("mime").unb64(data) or ""
end

local function swap_positions(encoded)
    local length = #encoded
    if length < 4 then
        return {}
    end
    if length < 11 then
        return {0, 2}
    end

    local n = math.min(4, math.floor((length + 9) / 10))
    local tmp = {}
    for i = length, length - n + 1, -1 do
        local byte = encoded:byte(i)
        local bin = {}
        repeat
            table.insert(bin, 1, tostring(byte % 2))
            byte = math.floor(byte / 2)
        until byte == 0
        local value = tonumber(table.concat(bin), 4) or 0
        table.insert(tmp, tostring(value))
    end
    tmp = table.concat(tmp)

    local result = {}
    local m = length - n - 2
    local step = #tostring(m)
    local i = 1
    while #result < 10 and i + step - 1 < #tmp do
        table.insert(result, (tonumber(tmp:sub(i, i + step - 1)) or 0) % m)
        local end2 = math.min(i + step, #tmp)
        if i + 1 <= #tmp then
            table.insert(result, (tonumber(tmp:sub(i + 1, end2)) or 0) % m)
        end
        i = i + step
    end
    return result
end

local function reverse_swaps(encoded, positions)
    -- The protocol swaps at most twenty character positions. Retain only those
    -- edits, rather than a Lua table entry for every byte of the chapter.
    local chars = {}
    local function char(index) return chars[index] or encoded:sub(index,index) end
    for i = #positions, 1, -2 do
        for k = 1, 0, -1 do
            local left, right = positions[i] + k + 1, positions[i - 1] + k + 1
            chars[left], chars[right] = char(right), char(left)
        end
    end
    local indices = {}
    for index in pairs(chars) do indices[#indices+1] = index end
    table.sort(indices)
    local parts, cursor = {}, 1
    for _,index in ipairs(indices) do
        parts[#parts+1] = encoded:sub(cursor,index-1)
        parts[#parts+1] = chars[index]
        cursor = index+1
    end
    parts[#parts+1] = encoded:sub(cursor)
    return table.concat(parts)
end

local function decode_encoded_body(body)
    if #body == 0 then
        return ""
    end
    local encoded = body:sub(2)
    local restored = reverse_swaps(encoded, swap_positions(encoded))
    return base64_decode(restored)
end

function M.decode_content_shards(e0, e1, e3)
    local body = checked_body(e0) .. checked_body(e1) .. checked_body(e3)
    return decode_encoded_body(body)
end

function M.decode_content_shard(e0)
    return decode_encoded_body(checked_body(e0))
end

return M

-- Preserve annotation rune and web-reader UTF-16 source offsets in one pass.
-- Fields 1-4 retain the existing annotation format; 5-6 address the web source.
-- WeRead heat-map ranges address the source HTML, not the rendered EPUB text.
local Source = {}
local function length(byte)
    if byte < 128 then return 1 elseif byte < 224 then return 2
    elseif byte < 240 then return 3 else return 4 end
end

function Source.plain(text)
    local bom = text:sub(1, 3) == "\239\187\191" and 1 or 0
    text = text:gsub("^\239\187\191", "")
    local i, count, units = 1, 0, bom
    while i <= #text do
        local size = length(text:byte(i))
        i, count, units = i + size, count + 1, units + (size == 4 and 2 or 1)
    end
    return { { 0, count, text, true, bom, units } }
end

function Source.index(html)
    local units = html:sub(1, 3) == "\239\187\191" and 1 or 0
    local start_units
    html = html:gsub("^\239\187\191", "")
    local spans, offset, i, start, pieces = {}, 0, 1, nil, {}
    local in_tag, quote, suppressed = false, nil, nil
    local tag = {}
    local function flush()
        if start then spans[#spans + 1] = { start, offset, table.concat(pieces), false, start_units, units } end
        start, start_units, pieces = nil, nil, {}
    end
    while i <= #html do
        local size = length(html:byte(i))
        local char = html:sub(i, i + size - 1)
        if in_tag then
            tag[#tag + 1] = char
            if quote then
                if char == quote then quote = nil end
            elseif char == '"' or char == "'" then quote = char
            elseif char == ">" then
                in_tag = false
                local name = table.concat(tag):lower()
                if name:match("^/?script[%s>]") or name:match("^/?style[%s>]") then
                    suppressed = name:sub(1, 1) ~= "/" or nil
                end
            end
        elseif char == "<" then
            flush()
            in_tag, tag = true, {}
        elseif not suppressed then
            start_units = start_units or units
            start = start or offset
            pieces[#pieces + 1] = char
        end
        i, offset, units = i + size, offset + 1, units + (size == 4 and 2 or 1)
    end
    flush()
    return spans
end

function Source.quote(spans, range, unit)
    if unit ~= nil and unit ~= "rune" and unit ~= "utf16" then return "", "unsupported_unit" end
    local utf16 = unit == "utf16"
    local first, last = tostring(range):match("^(%d+)%-(%d+)$")
    first, last = tonumber(first), tonumber(last)
    if not first or not last or first >= last then return "" end
    local pieces = {}
    for _, span in ipairs(spans or {}) do
        local from, to = span[1], span[2]
        if utf16 then
            from, to = span[5], span[6]
            if not from or not to then return "", "missing_utf16_index" end
        end
        if from < last and to > first then
            local offset, i, start_byte = from, 1, nil
            while i <= #span[3] and offset < last do
                if offset >= first and not start_byte then start_byte = i end
                local size = length(span[3]:byte(i))
                local step = utf16 and size == 4 and 2 or 1
                if offset < first and offset + step > first or offset + step > last then
                    return "", "partial_character"
                end
                i, offset = i + size, offset + step
            end
            if start_byte then
                local text = span[3]:sub(start_byte, i - 1)
                -- A cut entity cannot be interpreted safely.
                if span[4] then
                    pieces[#pieces + 1] = text
                else
                    if text:match("&[^;]*$")
                        or span[3]:sub(1, start_byte - 1):match("&[^;]*$") then return "" end
                    pieces[#pieces + 1] = require("util").htmlEntitiesToUtf8(text)
                end
            end
        end
    end
    return table.concat(pieces)
end
return Source

-- Preserve annotation rune and web-reader UTF-16 source offsets in one pass.
-- Fields 1-4 retain the existing annotation format; 5-6 address the web source.
-- WeRead heat-map ranges address the source HTML, not the rendered EPUB text.
local Source = {}
-- Stored on each HTML span so JSON round trips remain plain arrays. Older
-- indexes contain head/title text and cannot be repaired without the source.
Source.INDEX_VERSION = 2

function Source.is_current_span(span)
    return type(span) == "table" and type(span[3]) == "string"
        and type(span[5]) == "number" and type(span[6]) == "number"
        and (span[4] == true or span[7] == Source.INDEX_VERSION)
end
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
    local spans, bodies, offset, i, start, pieces = {}, {}, 0, 1, nil, {}
    local in_tag, quote, raw, special = false, nil, nil, nil
    local in_head, in_body, has_body = false, false, false
    local declaration, brackets = false, 0
    local tag = {}
    local function flush()
        if start then
            local span = { start, offset, table.concat(pieces), special == "cdata",
                start_units, units, Source.INDEX_VERSION }
            if in_body then bodies[#bodies + 1] = span end
            if not has_body then spans[#spans + 1] = span end
        end
        start, start_units, pieces = nil, nil, {}
    end
    while i <= #html do
        local size = length(html:byte(i))
        local char = html:sub(i, i + size - 1)
        if special == "comment" then
            if html:sub(i, i + 2) == "-->" then special, size = nil, 3 end
        elseif special == "cdata" then
            if html:sub(i, i + 2) == "]]>" then
                flush(); special, size = nil, 3
            elseif not in_head then
                start_units, start = start_units or units, start or offset
                pieces[#pieces + 1] = char
            end
        elseif in_tag then
            tag[#tag + 1] = char
            if quote then
                if char == quote then quote = nil end
            elseif char == '"' or char == "'" then quote = char
            elseif declaration and char == "[" then brackets = brackets + 1
            elseif declaration and char == "]" then brackets = math.max(0, brackets - 1)
            elseif char == ">" and brackets == 0 then
                in_tag = false
                local closing, name = table.concat(tag):lower():match("^(/?)([%w:_-]+)[%s/>]")
                if raw then
                    if closing == "/" and name == raw then raw = nil end
                elseif name == "head" then
                    in_head = closing ~= "/"
                elseif name == "body" then
                    in_body = closing ~= "/"
                    if in_body then
                        in_head, has_body, spans = false, true, {}
                    end
                elseif closing == "" and (name == "script" or name == "style" or name == "title")
                    and not table.concat(tag):match("/%s*>$") then
                    raw = name
                end
            end
        elseif raw then
            -- Script/style raw text and title RCDATA end only at their own
            -- closing tag. A '<' or fake body tag inside them is not markup.
            if html:sub(i, i + #raw + 3):lower():match("^</" .. raw .. "[%s>]") then
                in_tag, tag, declaration, brackets = true, {}, false, 0
            end
        elseif char == "<" then
            flush()
            if html:sub(i, i + 3) == "<!--" then
                special, size = "comment", 4
            elseif html:sub(i, i + 8) == "<![CDATA[" then
                special, size = "cdata", 9
            else
                in_tag, tag, declaration, brackets = true, {}, html:sub(i + 1, i + 1) == "!", 0
            end
        elseif not in_head then
            start_units = start_units or units
            start = start or offset
            pieces[#pieces + 1] = char
        end
        local step = #char == 1 and size or 1
        i, offset, units = i + size, offset + step, units + (#char == 4 and 2 or step)
    end
    flush()
    -- Full and concatenated XHTML contribute only their bodies. Body-less
    -- fragments remain supported, without collecting head/title metadata.
    return has_body and bodies or spans
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

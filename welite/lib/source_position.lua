-- Chapter-local source coordinates. Build off the reader's hot path and retain
-- at most one chapter; callers may yield/cancel every 256 decoded characters.
local M = {}
M.__index = M
-- Some legitimate chapters exceed 100k characters (including omnibus books).
-- Keep a finite chapter-local budget; yielding below still bounds UI work.
M.MAX_BYTES = 1024 * 1024
M.MAX_CHARACTERS = 256 * 1024
local function size(byte)
    if byte < 128 then return 1 elseif byte < 224 then return 2
    elseif byte < 240 then return 3 else return 4 end
end
local function boundary(value)
    return type(value) == 'number' and value >= 0 and value == math.floor(value)
end

function M.new(spans, options)
    options = options or {}
    local normalize = options.normalize or require('welite.lib.external_annotations').flatten_text
    local decode = options.decode or require('util').htmlEntitiesToUtf8
    local skip = options.skip or (not options.normalize
        and require('welite.lib.external_annotations').normalization_skip_length)
    local result = setmetatable({starts={}, ends={}, bytes={}}, M)
    local chunks, total, output, count, previous = {}, 0, 0, 0, 0
    for _, span in ipairs(spans or {}) do
        local text, offset, finish = span[3], span[5], span[6]
        if not boundary(offset) or not boundary(finish) then return nil, 'missing_utf16_index' end
        if type(text) ~= 'string' or offset < previous or finish < offset then return nil, 'invalid_source_index' end
        total = total + #text
        if total > M.MAX_BYTES then return nil, 'source_limit' end
        local i = 1
        while i <= #text do
            count = count + 1
            if count > M.MAX_CHARACTERS then return nil, 'source_limit' end
            if count % 256 == 0 and options.yield and options.yield() == false then return nil, 'cancelled' end
            local n = size(text:byte(i))
            local token, units = text:sub(i, i+n-1), n == 4 and 2 or 1
            if not span[4] and token == '&' then
                local entity = text:sub(i, i+31):match('^&[#%w]+;')
                if entity then
                    local value = decode(entity)
                    if value ~= entity then
                        -- One source entity must denote one Unicode character.
                        if value == '' or size(value:byte(1)) ~= #value then return nil, 'unsupported_entity' end
                        token, n, units = value, #entity, #entity
                    end
                end
            end
            local index = #result.starts+1
            result.starts[index], result.ends[index], result.bytes[index] = offset, offset+units, output+1
            chunks[#chunks+1], output = token, output+#token
            i, offset = i+n, offset+units
        end
        if offset ~= finish then return nil, 'invalid_source_index' end
        previous = finish
    end
    local decoded = table.concat(chunks)
    local kept, flat_bytes, skip_until = 0, 0, 0
    local original_count = #result.starts
    for index=1,original_count do
        if index % 256 == 0 and options.yield and options.yield() == false then return nil, 'cancelled' end
        local byte, token = result.bytes[index], chunks[index]
        if byte >= skip_until then
            -- Match on the fully decoded chapter, including markers split by
            -- inline tags/entities. Keep original UTF-16 coordinates unchanged.
            local ignored = skip and skip(decoded, byte) or (normalize(token)=='' and #token or 0)
            skip_until = byte + ignored
            if ignored == 0 then
                kept = kept + 1
                result.starts[kept],result.ends[kept],result.bytes[kept] =
                    result.starts[index],result.ends[index],flat_bytes+1
                chunks[kept],flat_bytes = token,flat_bytes+#token
            end
        end
    end
    for index=kept+1,original_count do
        result.starts[index],result.ends[index],result.bytes[index],chunks[index] = nil,nil,nil,nil
    end
    result.text = table.concat(chunks)
    -- Keep the fail-closed invariant if normalization rules ever diverge.
    if normalize(decoded) ~= result.text then return nil, 'unsupported_normalization' end
    if result.text == '' then return nil, 'source_empty' end
    return result
end

local function preceding(array, value)
    local lo, hi = 1, #array
    while lo <= hi do
        local mid = math.floor((lo+hi)/2)
        if array[mid] <= value then lo=mid+1 else hi=mid-1 end
    end
    return hi
end

function M:source_to_byte(offset)
    if not boundary(offset) then return nil, 'invalid_source_offset' end
    local index = preceding(self.starts, offset)
    if index > 0 and offset < self.ends[index] then
        if offset ~= self.starts[index] then return nil, 'partial_source_character' end
        return self.bytes[index]
    end
    -- A tag/whitespace offset addresses the next visible text, never a guessed
    -- percentage. End-of-chapter positions are handled by the reader boundary.
    if index < #self.starts then return self.bytes[index+1] end
    return nil, 'source_offset_outside_text'
end

function M:byte_to_source(byte)
    if not boundary(byte) or byte < 1 then return nil, 'invalid_text_offset' end
    local index = preceding(self.bytes, byte)
    if self.bytes[index] ~= byte then return nil, 'partial_text_character' end
    return self.starts[index]
end

-- Align a short context around a known source character with chapter text.
-- Repeated contexts are ambiguous: do not silently choose the first hit.
function M:locate(offset, flat)
    if type(flat) ~= 'string' or #flat > M.MAX_BYTES then return nil, 'rendered_text_limit' end
    local byte, reason = self:source_to_byte(offset)
    if not byte then return nil, reason end
    local index = preceding(self.bytes, byte)
    for _,width in ipairs({16,64,256}) do
        local first = self.bytes[math.max(1,index-width)]
        local last = self.bytes[math.min(#self.bytes,index+width*2)+1] or #self.text+1
        local needle = self.text:sub(first,last-1)
        local at = flat:find(needle,1,true)
        if not at then return nil, 'source_text_mismatch' end
        if not flat:find(needle,at+1,true) then return at+byte-first end
    end
    return nil, 'source_text_ambiguous'
end
-- Reverse correspondence for a known byte boundary in normalized chapter text.
-- Extra headings are allowed when the surrounding text still has a unique match.
function M:text_to_source(flat, byte)
    if type(flat) ~= 'string' or #flat > M.MAX_BYTES then return nil, 'rendered_text_limit' end
    if not boundary(byte) or byte < 1 or byte > #flat then return nil, 'invalid_text_offset' end
    local current = flat:byte(byte)
    if current >= 128 and current < 192 then return nil, 'partial_text_character' end
    local first, last = math.max(1,byte-64), math.min(#flat+1,byte+128)
    while first < byte and flat:byte(first) >= 128 and flat:byte(first) < 192 do first=first+1 end
    while last <= #flat and flat:byte(last) >= 128 and flat:byte(last) < 192 do last=last+1 end
    local needle = flat:sub(first,last-1)
    local at = self.text:find(needle,1,true)
    if not at then return nil, 'source_text_mismatch' end
    if self.text:find(needle,at+1,true) then return nil, 'source_text_ambiguous' end
    return self:byte_to_source(at+byte-first)
end

-- Resolve one remote source coordinate using the existing chapter-only DOM
-- walker. The caller owns scheduling and must provide the current chapter range.
function M:locate_document(document, range, offset, options)
    options = options or {}
    if not range or not range.start_xpointer or not range.end_xpointer then
        return nil, 'chapter_boundary_unavailable'
    end
    local Locator = require('welite.lib.external_annotations')
    local ok, extracted = pcall(document.getTextFromXPointers, document,
        range.start_xpointer, range.end_xpointer)
    if document.clearSelection then document:clearSelection() end
    if not ok or type(extracted) ~= 'string' then return nil, 'chapter_text_unavailable' end
    if #extracted > M.MAX_BYTES then return nil, 'rendered_text_limit' end
    local flat = Locator.flatten_text(extracted)
    local byte, reason = self:locate(offset, flat)
    if not byte then return nil, reason end
    local next_byte = byte + size(flat:byte(byte))
    local walk = Locator.new_chapter_walk(document, extracted, range.end_xpointer)
    walk.needed = {[byte]=true, [next_byte]=true}
    local cancelled = false
    walk.yield = function()
        if options.yield and options.yield() == false then
            cancelled = true
            -- Stop this walk without allowing it to continue on stale context.
            error('source_position_cancelled')
        end
    end
    local walked, found = pcall(function()
        return Locator.advance_chapter_walk(walk, byte)
            and Locator.advance_chapter_walk(walk, next_byte)
    end)
    if cancelled then return nil, 'cancelled' end
    if not walked or not found then return nil, 'document_walk_failed' end
    local xp = walk.xp_at[byte]
    local verified, text = pcall(document.getTextFromXPointers, document, xp, walk.xp_at[next_byte])
    if document.clearSelection then document:clearSelection() end
    if not verified or type(text) ~= 'string'
        or Locator.flatten_text(text) ~= flat:sub(byte,next_byte-1) then
        return nil, 'document_text_mismatch'
    end
    return xp
end
-- Capture an immutable reader XPointer. Prefix/suffix agreement prevents a
-- pointer outside this chapter or a changed document from producing an offset.
function M.snapshot_document(document, range, xp)
    if not range or not range.start_xpointer or not range.end_xpointer or not xp then
        return nil, 'chapter_boundary_unavailable'
    end
    if type(document.compareXPointers)~='function' then return nil,'document_position_unsupported' end
    local ok_start,from=pcall(document.compareXPointers,document,range.start_xpointer,xp)
    local ok_end,to=pcall(document.compareXPointers,document,xp,range.end_xpointer)
    -- CREngine returns 1 when the first pointer precedes the second.
    if not ok_start or not ok_end or (from~=0 and from~=1) or to~=1 then
        return nil,'position_outside_chapter'
    end
    local normalize=require('welite.lib.external_annotations').flatten_text
    local function text(first,last)
        local ok,value=pcall(document.getTextFromXPointers,document,first,last)
        if document.clearSelection then document:clearSelection() end
        if not ok or type(value)~='string' then return nil end
        if #value>M.MAX_BYTES then return nil end
        return normalize(value)
    end
    local full=text(range.start_xpointer,range.end_xpointer)
    local prefix=text(range.start_xpointer,xp)
    local suffix=text(xp,range.end_xpointer)
    if not full or not prefix or not suffix then return nil,'chapter_text_unavailable' end
    if full~=prefix..suffix then return nil,'document_text_mismatch' end
    local byte=#prefix+1
    if byte>#full then return nil,'position_outside_text' end
    local first,last=math.max(1,byte-1024),math.min(#full+1,byte+2048)
    while first<byte and full:byte(first)>=128 and full:byte(first)<192 do first=first+1 end
    while last<=#full and full:byte(last)>=128 and full:byte(last)<192 do last=last+1 end
    local stop,count=1,0
    while stop<=#suffix and count<32 do stop=stop+size(suffix:byte(stop));count=count+1 end
    return {version=1,text=full:sub(first,last-1),byte=byte-first+1,summary=suffix:sub(1,stop-1)}
end

function M:capture_snapshot(snapshot)
    if type(snapshot)~='table' or snapshot.version~=1 or type(snapshot.text)~='string'
        or #snapshot.text>3075 then return nil,'invalid_source_snapshot' end
    local offset,reason=self:text_to_source(snapshot.text,snapshot.byte)
    if not offset then return nil,reason end
    return offset,nil,snapshot.summary
end

function M:capture_document(document,range,xp)
    local snapshot,reason=M.snapshot_document(document,range,xp)
    if not snapshot then return nil,reason end
    return self:capture_snapshot(snapshot)
end
return M

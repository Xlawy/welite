-- Translate chapter-relative positions through the actual EPUB layout.
-- Offsets within a chapter remain proportional to its rendered span; this is
-- not a source-character index. Never infer chapter identity from page ratios.
local Chapters = require('weread.lib.annotation_chapters')
local Mapper = require('weread.lib.position_mapper')
local M = {}
M.__index = M
local function clamp(value, lo, hi) return math.max(lo, math.min(hi, value)) end
local function file_version(path)
    local ok,lfs=pcall(require,'libs/libkoreader-lfs')
    if not ok then return end
    local attr=lfs.attributes(path)
    if attr and attr.mode=='file' then return {size=attr.size,mtime=attr.modification} end
end

function M.new(document, context, mode)
    if not document.getCurrentPage or not document.getPageCount
        or not document.getPageFromXPointer
        or (mode ~= 'page' and mode ~= nil
            and (not document.getPosFromXPointer or not document.getCurrentPos)) then
        return setmetatable({document=document, context=context, mode=mode,
            error='document_position_unsupported'}, M)
    end
    local descriptor = Chapters.descriptor(context.book, context.path)
    local _, ranges = Chapters.map(document, context.chapters, descriptor)
    local result=setmetatable({document=document, context=context, ranges=ranges,
        catalog=Mapper.catalog(context.chapters), mode=mode or 'page',
        file_version=file_version(context.path)}, M)
    result:restore_target(context.book.last_local_position)
    return result
end

function M:layout()
    local doc = self.document
    local pages = doc:getPageCount()
    local height = doc.info and doc.info.doc_height
    local hash = doc.getDocumentRenderingHash and doc:getDocumentRenderingHash(true)
    if self.entries and self.pages == pages and self.height == height and self.hash == hash then return self.entries end
    self.landing=nil
    local entries, by_uid = {}, {}
    for _, item in ipairs(self.catalog.chapters) do
        local range = self.ranges[tostring(item.uid)]
        if range then
            local first, last
            if self.mode == 'page' then
                first = doc:getPageFromXPointer(range.start_xpointer)
                last = range.end_xpointer and doc:getPageFromXPointer(range.end_xpointer) or pages + 1
                -- The final visible word belongs to the last page, not the
                -- first page of another chapter. Include that final page.
                if range.ends_document then last = pages + 1 end
            else
                first = doc:getPosFromXPointer(range.start_xpointer)
                last = range.end_xpointer and doc:getPosFromXPointer(range.end_xpointer) or height
                if range.ends_document then last = height end
            end
            if first and last and last >= first then
                local entry = {first=first, last=last, item=item}
                entries[#entries+1] = entry
                by_uid[tostring(item.uid)] = entry
            end
        end
    end
    table.sort(entries, function(a,b) return a.first < b.first end)
    if self.mode == 'page' then
        for index=2,#entries do
            if entries[index-1].first==entries[index].first then
                entries[index-1].ambiguous=true
                entries[index].ambiguous=true
            end
        end
    end
    self.entries, self.by_uid, self.pages, self.height, self.hash = entries, by_uid, pages, height, hash
    return entries
end

function M:capture()
    if self.error then return nil, self.error end
    local entries = self:layout()
    local coordinate = self.mode == 'page' and self.document:getCurrentPage()
        or self.document:getCurrentPos()
    if self.landing and coordinate~=self.landing.page then self.landing=nil end
    local lo, hi = 1, #entries
    while lo <= hi do
        local mid = math.floor((lo+hi)/2)
        if entries[mid].first <= coordinate then lo=mid+1 else hi=mid-1 end
    end
    local entry = entries[hi]
    -- Front matter before a known first chapter represents its start.
    if not entry and entries[1] and entries[1].item.index == 1 then
        entry, hi = entries[1], 1
    end
    if not entry or coordinate >= entry.last then return nil, 'chapter_mapping_unavailable' end
    if entry.ambiguous then
        return nil, 'chapter_page_ambiguous'
    end
    if entry.last <= entry.first then return nil, 'chapter_span_unavailable' end
    local fraction = clamp((coordinate-entry.first)/(entry.last-entry.first),0,1)
    local landing=self.landing
    if landing then
        if coordinate==landing.page and tostring(entry.item.uid)==landing.uid then
            fraction=landing.fraction
        else self.landing=nil end
    end
    local position, reason = Mapper.local_to_remote(self.context.chapters, fraction, {
        catalog=self.catalog, current_chapter_uid=entry.item.uid,
        summary=self.context.book.summary or self.context.book.title or '',
    })
    if position then
        position.position_basis='rendered_chapter_span'
        if self.landing then
            position.chapter_offset=self.landing.offset
            if self.landing.summary~=nil then position.summary=self.landing.summary end
            if self.landing.percent~=nil then
                position.percent=self.landing.percent
                position.fraction=self.landing.percent/100
            end
            position.position_basis='confirmed_remote_offset'
            if self.file_version and self.hash and self.context.account then
                position.confirmed_layout={account=self.context.account,path=self.context.path,
                    size=self.file_version.size,mtime=self.file_version.mtime,hash=self.hash,
                    pages=self.pages,height=self.height,page=self.landing.page}
            end
        end
    end
    return position, reason
end

-- A persisted offset is only reusable in the same file/layout/account and
-- on the page the host restored. It does not grant permission to upload.
function M:restore_target(position)
    local saved=type(position)=='table' and position.confirmed_layout
    local version=self.file_version
    if self.mode~='page' or not version or type(saved)~='table'
        or position.position_basis~='confirmed_remote_offset'
        or not self.context.account or saved.account~=self.context.account
        or saved.path~=self.context.path or saved.size~=version.size
        or saved.mtime~=version.mtime then return false end
    self:layout()
    if not self.hash or saved.hash~=self.hash or saved.pages~=self.pages
        or saved.height~=self.height or self.document:getCurrentPage()~=saved.page then return false end
    self:accept_target(position, saved.page)
    return self.landing~=nil
end

-- Page display quantizes a remote offset to its containing page. Preserve the
-- confirmed offset while that page remains visible; observing any other page
-- or a new layout invalidates it. Merely calculating a target never changes it.
function M:accept_target(remote, source_page)
    self.landing=nil
    if self.mode~='page' or remote.has_chapter_offset==false or remote.chapter_offset==nil then return end
    local _,reason,page=self:target(remote)
    if source_page then reason,page=nil,source_page end
    if reason or not page or self.document:getCurrentPage()~=page then return end
    local item=self.catalog.by_uid[tostring(remote.chapter_uid)]
    if not item or item.words<=0 then return end
    self.landing={page=page,uid=tostring(item.uid),fraction=clamp(remote.chapter_offset/item.words,0,1),
        -- Source HTML coordinates can exceed catalog wordCount. A confirmed
        -- server position must survive quantization without changing units.
        offset=math.floor(math.max(0,remote.chapter_offset)),summary=remote.summary,
        percent=tonumber(remote.percent) and clamp(tonumber(remote.percent),0,100) or nil}
end

function M:target(remote)
    if self.error then return nil, self.error end
    self:layout()
    local item = remote.chapter_uid and self.catalog.by_uid[tostring(remote.chapter_uid)]
    if not item or item.words <= 0 then return nil, 'remote_chapter_not_found' end
    local entry = self.by_uid[tostring(item.uid)]
    if not entry then return nil, 'chapter_mapping_unavailable' end
    if entry.ambiguous then return nil, 'chapter_page_ambiguous' end
    if entry.last <= entry.first then return nil, 'chapter_span_unavailable' end
    local fraction
    if remote.has_chapter_offset ~= false and remote.chapter_offset ~= nil then
        fraction = clamp(remote.chapter_offset/item.words,0,1)
    else
        fraction = clamp(((tonumber(remote.percent) or 0)/100*self.catalog.total_words-item.before)/item.words,0,1)
    end
    local coordinate = entry.first+fraction*(entry.last-entry.first)
    if self.mode == 'page' then
        -- Keep an end-of-chapter target on that chapter's last page.
        coordinate=clamp(math.floor(coordinate+1e-7),entry.first,math.max(entry.first,entry.last-1))
        return clamp(coordinate/self.pages,0,1), nil, coordinate
    end
    if not self.height or self.height <= 0 then return nil, 'layout_unavailable' end
    return clamp(coordinate/self.height,0,1)
end
return M

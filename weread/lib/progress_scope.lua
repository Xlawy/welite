-- Select known downloads plus the ten most recently read books. Metadata only:
-- no filesystem scans or network calls on shelf display/page changes.
local M={RECENT_LIMIT=10}
local function stamp(value)
    local n=tonumber(value)
    if not n or n~=n or n==math.huge or n<=0 then return 0 end
    if n>100000000000 then n=n/1000 end -- tolerate millisecond shelf timestamps
    return n
end
local function downloaded(record)
    if type(record)~='table' then return false end
    for _,key in ipairs({'cached_full_book','cached_file'}) do
        if type(record[key])=='string' and record[key]~='' then return true end
    end
    for _,path in pairs(record.cached_chapters or {}) do
        if type(path)=='string' and path~='' then return true end
    end
    return false
end
function M.select(cloud,saved)
    saved=saved or {}
    local candidates,order,recent,selected={},{},{},{}
    local function add(book,id)
        id=tostring(id or '')
        if id=='' or id:sub(1,7)=='MP_WXS_' or candidates[id] then return end
        local record=saved[id] or saved[tonumber(id)] or {}
        local local_position=record.last_local_position or {}
        local when=math.max(stamp(book.readUpdateTime),stamp(record.readUpdateTime),stamp(local_position.captured_at))
        candidates[id]=book;order[#order+1]=id
        if downloaded(record) then selected[id]=true end
        if when>0 then
            local index=1
            while recent[index] and (recent[index].time>when or
                (recent[index].time==when and recent[index].id<id)) do index=index+1 end
            if index<=M.RECENT_LIMIT then
                table.insert(recent,index,{id=id,time=when})
                if #recent>M.RECENT_LIMIT then table.remove(recent) end
            end
        end
    end
    for _,book in ipairs(cloud or {}) do add(book,book.bookId or book.book_id) end
    for id,record in pairs(saved) do
        if type(record)=='table' then
            -- Copies for local-only records must not mutate persistent records.
            add({bookId=tostring(id),readUpdateTime=record.readUpdateTime},id)
        end
    end
    for _,entry in ipairs(recent) do selected[entry.id]=true end
    local result={}
    for _,id in ipairs(order) do if selected[id] then result[#result+1]=candidates[id] end end
    return result,selected
end
return M

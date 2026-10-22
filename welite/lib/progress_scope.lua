-- Select current-account downloads plus the ten most recently read books. Metadata only:
-- no filesystem scans or network calls on shelf display/page changes.
local M={RECENT_LIMIT=10}
local OWNER_FIELDS={
    {'last_local_position','account_id'}, {'pending_upload_position','account_id'},
    {'last_uploaded_position','account_id'}, {'last_reported_position','account'},
    {'home_remote_position','account'}, {'last_remote_position','account_id'},
}
local function account_id(value)
    if (type(value)=='string' and value~='') or type(value)=='number' then return tostring(value) end
end
-- Local reading identifies the active owner before older cloud observations.
-- Legacy records without account evidence stay cached, but cannot authorize a
-- local-only network request. Current shelf membership supplies that evidence.
function M.record_account(record)
    if type(record)~='table' then return end
    for _,field in ipairs(OWNER_FIELDS) do
        local position=record[field[1]]
        local owner=type(position)=='table' and account_id(position[field[2]])
        if owner then return owner end
    end
end
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
function M.select(cloud,saved,account)
    saved=saved or {}
    account=account_id(account)
    local candidates,order,recent,selected={},{},{},{}
    local function add(book,id,on_shelf)
        id=tostring(id or '')
        if id=='' or id:sub(1,7)=='MP_WXS_' or candidates[id] then return end
        local record=saved[id] or saved[tonumber(id)] or {}
        local owner=M.record_account(record)
        local own=account~=nil and owner==account
        if not on_shelf and not own then return end
        local local_position=own and record.last_local_position or {}
        local when=math.max(stamp(book.readUpdateTime),own and stamp(record.readUpdateTime) or 0,
            stamp(type(local_position)=='table' and local_position.captured_at))
        candidates[id]=book;order[#order+1]=id
        if (own or (on_shelf and owner==nil)) and downloaded(record) then selected[id]=true end
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
    for _,book in ipairs(cloud or {}) do add(book,book.bookId or book.book_id,true) end
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

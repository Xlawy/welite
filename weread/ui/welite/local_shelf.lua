-- Merge known local records, including chapters and books removed from the cloud.
-- The injected predicate validates published files using the community cache layer.
local M={}
function M.select(cloud,saved,has_download)
    local result,seen={},{}
    local function add(book,id)
        id=tostring(id or '')
        if id=='' or seen[id] then return end
        seen[id]=true
        local record=saved[id] or saved[tonumber(id)]
        if not record or not has_download(record) then return end
        local item={}
        for k,v in pairs(record) do item[k]=v end
        for k,v in pairs(book or {}) do item[k]=v end
        item.bookId=id
        result[#result+1]=item
    end
    for _,book in ipairs(cloud or {}) do add(book,book.bookId or book.book_id) end
    local ids={}
    for id in pairs(saved or {}) do ids[#ids+1]=tostring(id) end
    table.sort(ids)
    for _,id in ipairs(ids) do add(nil,id) end
    return result
end
return M

-- Normalize bounded WeRead store results without mutating source records.
local M={limit=10}
function M.query(value)
    local query=tostring(value or ''):match('^%s*(.-)%s*$')
    if query=='' then return nil,'empty_query' end
    if #query>512 then return nil,'query_too_long' end
    return query
end
function M.results(data)
    assert(type(data)=='table' and type(data.results)=='table','invalid search response')
    local items,seen={},{}
    for _,group in ipairs(data.results) do
        for _,entry in ipairs(type(group)=='table' and group.books or {}) do
            local source=type(entry)=='table' and (entry.bookInfo or entry)
            local id=type(source)=='table' and (source.bookId or source.book_id)
            if (type(id)=='string' and id~='' or type(id)=='number') and not seen[tostring(id)] then
                local book={}
                for key,value in pairs(source) do book[key]=value end
                book.bookId=tostring(id)
                if type(book.title)~='string' or book.title=='' then book.title=book.bookId end
                if type(book.author)~='string' then book.author='' end
                items[#items+1]=book;seen[book.bookId]=true
                if #items==M.limit then return items end
            end
        end
    end
    return items
end
return M

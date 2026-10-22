-- Pure collection selection: preserve server order and never mutate cached items.
local C={sorts={cloud='云端顺序',recent='最近阅读',added='最近加入',title='书名'}}
function C.select(items,local_items,downloads,category,sort,query,download_filter)
    local rows,seen={},{};query=(query or ''):lower()
    local function add(item,rank)
        local key=item.kind..':'..item.id
        if seen[key] then return end;seen[key]=true
        if category=='local' and not downloads[key] then return end
        if download_filter=='none' and downloads[key] then return end
        if (download_filter=='full' or download_filter=='partial') and downloads[key]~=download_filter then return end
        if query~='' and not (item.title..' '..item.author):lower():find(query,1,true) then return end
        rows[#rows+1]={item=item,rank=rank}
    end
    for i,item in ipairs(items) do add(item,i) end
    if category=='local' then for i,item in ipairs(local_items or {}) do add(item,#items+i) end end
    table.sort(rows,function(a,b)
        if sort=='title' then
            local x,y=a.item.title:lower(),b.item.title:lower()
            if x~=y then return x<y end
        elseif sort=='recent' or sort=='added' then
            local key=sort=='recent' and 'read_updated' or 'added'
            local x,y=a.item[key] or -1,b.item[key] or -1
            if x~=y then return x>y end
        end
        return a.rank<b.rank
    end)
    local result={};for _,row in ipairs(rows) do result[#result+1]=row.item end
    return result
end
return C

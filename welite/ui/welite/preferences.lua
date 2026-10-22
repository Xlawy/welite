-- Small host-owned preferences, separate from account state. No network or clock changes.
local P={}
local key='welite_preferences'
function P.read(settings)
    local value=(settings or G_reader_settings):readSetting(key)
    value=type(value)=='table' and value or {}
    local offset=value.offset
    if type(offset)~='number' or offset%15~=0 or offset< -720 or offset>840 then offset=nil end
    return {offset=offset,autostart=value.autostart==true,
        decided=type(value.autostart)=='boolean'}
end
function P.save(change,settings)
    settings=settings or G_reader_settings
    local value=P.read(settings)
    if not value.decided then value.autostart=nil end
    if change.timezone then value.offset=change.offset end
    if change.autostart~=nil then value.autostart=change.autostart end
    value.decided=nil
    settings:saveSetting(key,value)
    settings:flush()
end
-- Shelf display choices are device preferences, not account content/search history.
function P.readShelf(settings)
    local v=(settings or G_reader_settings):readSetting('welite_shelf_preferences')
    v=type(v)=='table' and v or {}
    local sorts={cloud=true,recent=true,added=true,title=true}
    local downloads={all=true,full=true,partial=true,none=true}
    local category=v.category=='local' and 'local' or 'shelf'
    local download=downloads[v.download_filter] and v.download_filter or 'all'
    if category=='local' and download=='none' then download='all' end
    return {category=category,sort=sorts[v.sort] and v.sort or 'cloud',download_filter=download}
end
function P.saveShelf(value,settings)
    settings=settings or G_reader_settings
    local old=P.readShelf(settings)
    if old.category==value.category and old.sort==value.sort and old.download_filter==value.download_filter then return end
    settings:saveSetting('welite_shelf_preferences',{
        category=value.category,sort=value.sort,download_filter=value.download_filter})
    settings:flush()
end
function P.parse(text)
    local sign,h,m=text:match('^([+-])(%d%d):(%d%d)$')
    h,m=tonumber(h),tonumber(m)
    if not h or m>=60 or m%15~=0 then return end
    local n=(h*60+m)*(sign=='-' and -1 or 1)
    if n>=-720 and n<=840 then return n end
end
function P.label(offset)
    if offset==nil then return '跟随系统' end
    return string.format('UTC%s%02d:%02d',offset<0 and '-' or '+',math.floor(math.abs(offset)/60),math.abs(offset)%60)
end
function P.date(format,now,settings)
    local offset=P.read(settings).offset
    now=now or os.time()
    return offset and os.date('!'..format,now+offset*60) or os.date(format,now)
end
return P

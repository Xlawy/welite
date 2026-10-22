-- Reading data is measured in seconds. Missing values remain unknown, never zero.
local Reading = {}
Reading.modes = {weekly="本周", monthly="本月", annually="今年", overall="累计"}
function Reading.number(value, maximum)
    if type(value)=="number" and value==value and value>=0 and value<=(maximum or 1e12) then return value end
end
-- Service day buckets observed at UTC+8 midnight; independent of the device timezone.
function Reading.dayStart(now) return math.floor((now+28800)/86400)*86400-28800 end
function Reading.dailyTimes(buckets)
    if type(buckets)~="table" then return nil end
    local result,count={},0
    for key,value in pairs(buckets) do
        count=count+1
        local stamp=tonumber(key)
        if count>31 or not Reading.number(stamp,4102444800) or stamp~=Reading.dayStart(stamp)
            or not Reading.number(value) then return nil end
        result[tostring(stamp)]=value
    end
    return result
end
function Reading.today(overview,now)
    now=now or os.time();local chosen
    for _,mode in ipairs({"monthly","weekly"}) do
        local stat=(overview or {})[mode]
        if type(stat)=="table" and type(stat.daily_times)=="table" and Reading.number(stat.updated,4102444800)
            and stat.updated<=now and Reading.dayStart(stat.updated)==Reading.dayStart(now)
            and (not chosen or stat.updated>=chosen.updated) then chosen=stat end
    end
    local seconds=chosen and Reading.number(chosen.daily_times[tostring(Reading.dayStart(now))])
    if seconds then return {total_seconds=seconds,updated=chosen.updated,day=Reading.dayStart(now)} end
end
function Reading.fresh(stat,mode,now)
    local updated=type(stat)=="table" and Reading.number(stat.updated,4102444800)
    if not updated or now<updated or now-updated>=3600 then return false end
    if mode=="weekly" or mode=="monthly" then
        if type(stat.daily_times)~="table" or Reading.dayStart(updated)~=Reading.dayStart(now) then return false end
    end
    local format=({weekly="%Y-%W",monthly="%Y-%m",annually="%Y"})[mode]
    return mode=="overall" or (format~=nil and os.date("!"..format,updated+28800)==os.date("!"..format,now+28800))
end
function Reading.duration(seconds)
    seconds=Reading.number(seconds)
    if not seconds then return "暂无数据" end
    if seconds==0 then return "0 分钟" end
    if seconds<60 then return "不足 1 分钟" end
    local minutes=math.floor(seconds/60)
    if minutes<60 then return minutes.." 分钟" end
    return math.floor(minutes/60).." 小时 "..(minutes%60).." 分钟"
end
function Reading.summary(data, mode)
    if type(data)~="table" or not Reading.modes[mode] then return nil,{kind="invalid_statistics"} end
    local total=Reading.number(data.totalReadTime)
    if not total then return nil,{kind="invalid_statistics"} end
    local result={mode=mode,total_seconds=total,days=Reading.number(data.readDays,100000),
        average_seconds=Reading.number(data.dayAverageReadTime),base_time=Reading.number(data.baseTime),top={}}
    if mode=="weekly" or mode=="monthly" then result.daily_times=Reading.dailyTimes(data.readTimes) end
    for n,entry in ipairs(type(data.readLongest)=="table" and data.readLongest or {}) do
        if n>10 then break end
        if type(entry)=="table" then
            local book=entry.book or entry.albumInfo
            if type(book)=="table" then
                local title=book.title or book.name
                if type(title)=="string" and #title<=4096 then
                    result.top[#result.top+1]={title=title,seconds=Reading.number(entry.readTime)}
                end
            end
        end
    end
    return result
end
function Reading.progress(data)
    if type(data)~="table" or type(data.book)~="table" then return nil,{kind="invalid_progress"} end
    local book=data.book
    return {version=book.bookVersion and tostring(book.bookVersion) or nil,
        chapter=book.chapterUid~=nil and tostring(book.chapterUid) or nil,
        offset=Reading.number(book.chapterOffset,100000000),percent=Reading.number(book.progress,100),seconds=Reading.number(book.recordReadingTime),
        updated=Reading.number(book.updateTime,4102444800),
        finished=book.progress==100 and Reading.number(book.finishTime,4102444800)~=nil}
end
return Reading

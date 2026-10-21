-- Native font measurement and cached host status; no networking in the paint path.
local D={}
function D.status(device,network,now)
    local wifi='WIFI —'
    if device:hasWifiToggle() then
        if network.is_connected==true then wifi='WIFI已连接'
        elseif network.is_connected==false or network.is_wifi_on==false then wifi='WIFI未连接' end
    end
    local capacity
    if device:hasBattery() then
        local ok,value=pcall(function() return device:getPowerDevice():getCapacity() end)
        if ok then capacity=require('weread.ui.welite.reading').number(value,100) end
    end
    return {wifi=wifi,battery=capacity and (math.floor(capacity)..'%') or '—',capacity=capacity,time=require('weread.ui.welite.preferences').date('%H:%M',now)}
end
function D.duration(seconds,width,measure)
    seconds=require('weread.ui.welite.reading').number(seconds)
    local text
    if not seconds then text='—'
    elseif seconds==0 then text='0 分钟'
    elseif seconds<60 then text='不足 1 分钟'
    else
        local minutes=math.floor(seconds/60)
        text=minutes<60 and (minutes..' 分钟') or (math.floor(minutes/60)..' 小时 '..(minutes%60)..' 分')
    end
    if measure(text,23)<=width then return {text=text,size=23} end
    text=text:gsub(' ','')
    for size=23,18,-1 do if measure(text,size)<=width then return {text=text,size=size} end end
    local hours=math.floor((seconds or 0)/3600)
    local main=hours..'小时'
    if measure(main,18)>width then
        main='约'..string.format('%.1f',hours/(hours>=1e8 and 1e8 or 1e4))..(hours>=1e8 and '亿' or '万')..'小时'
    end
    return {text=main,size=18,secondary=(math.floor((seconds or 0)/60)%60)..'分'}
end
function D.measure(text,size)
    local widget=require('ui/widget/textwidget'):new{text=text,face=require('ui/font'):getFace('cfont',size),bold=true,padding=0}
    local width=widget:getSize().w;widget:free();return width
end
return D

-- Host device boundary. Snapshot is cache-only; radio dialogs belong to KOReader.
local C={};C.__index=C
function C.new(host, deps)
    deps=deps or {}
    return setmetatable({host=host,device=deps.device or require('device'),
        network=deps.network or require('ui/network/manager'),ui=deps.ui or require('ui/uimanager'),
        settings=deps.settings or G_reader_settings},C)
end
function C:snapshot()
    local d,n=self.device,self.network
    local state=require('weread.ui.welite.display').status(d,n)
    state.wifi_supported=d:hasWifiToggle()
    state.wifi_on=n.is_wifi_on==true
    state.network=n.lease_ssid or (n.is_connected and '选择网络 ›' or '未连接 ›')
    state.night=self.settings:isTrue('night_mode')
    state.light_supported=d:hasFrontlight()
    if state.light_supported then
        local p=d:getPowerDevice();state.light_on=p:isFrontlightOn()
        local range=p.fl_max-p.fl_min
        state.brightness=range>0 and math.floor((p.fl_intensity-p.fl_min)/range*100+0.5) or 0
    end
    return state
end
function C:brightness(percent)
    if not self.device:hasFrontlight() then return false end
    local p=self.device:getPowerDevice()
    if not p:isFrontlightOn() then return false end
    local value=math.floor(p.fl_min+(p.fl_max-p.fl_min)*math.max(0,math.min(100,percent))/100+0.5)
    p:setIntensity(value);return true
end
function C:step(delta)
    if not self.device:hasFrontlight() then return false end
    local p=self.device:getPowerDevice()
    if not p:isFrontlightOn() then return false end
    p:setIntensity(math.max(p.fl_min,math.min(p.fl_max,p.fl_intensity+delta)))
    return true
end
function C:light()
    if not self.device:hasFrontlight() then return false end
    local p=self.device:getPowerDevice()
    if not p:isFrontlightOn() and p.fl_intensity<=p.fl_min then
        p:setIntensity(p.fl_min+1)
    else p:toggleFrontlight() end
    return true
end
function C:night()
    -- Send to exactly one listener: broadcasting with two host UIs could toggle twice.
    require('device/devicelistener'):new{ui=self.host}:onToggleNightMode()
end
function C:cancel() if self.radio then self.radio:cancel() end end
function C:refresh() self.ui:setDirty('all','full') end
function C:weliteSettings()
    if self.plugin_settings then self.plugin_settings();return true end
    if self.host and self.host.welite then self.host.welite:showSettings();return true end
    return false
end
function C:settingsMenu()
    if self.host and self.host.menu then self.host.menu:onShowMenu();return true end
    return false
end
function C:wifi(select_network)
    if not self.device:hasWifiToggle() then return false end
    if self.device:isAndroid() then
        if select_network then self.network:openSettings()
        elseif self.network.is_wifi_on then self.network:toggleWifiOff(nil,true)
        else self.network:toggleWifiOn(nil,false,true) end
    elseif not select_network and self.network.is_wifi_on then
        self.network:toggleWifiOff(nil,true)
    else
        -- Kindle and restore-capable hosts can power up without the host's
        -- blocking scan dialog. The actual scan runs in one bounded child.
        local async=self.device.isKindle and self.device:isKindle()
            or self.device.hasWifiRestore and self.device:hasWifiRestore()
        if not self.network.is_wifi_on then
            if not async then
                -- Platform-specific native UI fallback; never emulate hardware.
                self.network:toggleWifiOn(nil,select_network,true)
                return true
            end
            self.network:restoreWifiAsync()
        end
        self.radio=self.radio or require('weread.ui.welite.wifi').new{network=self.network,ui=self.ui}
        return self.radio:scan()
    end
    return true
end
function C.reading(host,result)
    if not host or not host.document then return nil end
    local doc=host.document
    local page=host.rolling and host.rolling.current_page or host.paging and host.paging.current_page
    local total=doc.info and doc.info.number_of_pages
    local percent
    if page and total and total>0 and page>0 and page<=total then
        percent=page/total
        if host.rolling and host.rolling.getLastPercent then
            local ok,value=pcall(host.rolling.getLastPercent,host.rolling)
            if ok and type(value)=='number' and value==value and value>=0 and value<=1 then percent=value end
        end
    end
    local chapter
    if host.toc and page then
        local ok,value=pcall(host.toc.getTocTitleByPage,host.toc,page)
        if ok and value~='' then chapter=value end
    end
    return {title=result and result.item and result.item.title or (host.doc_props or {}).title or '当前书籍',
        chapter=chapter or '章节未知',percent=percent and math.floor(percent*100)..'%' or '—',
        pages=(result and not result.full and '本章 ' or '全书 ')..(percent and (page..' / '..total..' 页') or '—')}
end
return C

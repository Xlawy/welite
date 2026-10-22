-- One cancellable scan, using the host backend and native network picker.
local W={};W.__index=W
function W.new(deps)
    deps=deps or {}
    local ui=deps.ui or require('ui/uimanager')
    return setmetatable({ui=ui,network=deps.network or require('ui/network/manager'),
        worker=deps.worker or require('welite.ui.welite.worker').new(ui),generation=0},W)
end
function W:cancel()
    self.generation=self.generation+1;self.worker:cancel()
    if self.picker then local picker=self.picker;self.picker=nil;self.ui:close(picker) end
    if self.dialog then
        local dialog=self.dialog;self.dialog=nil;self.ui:close(dialog)
    end
end
function W:scan()
    if self.dialog then return false end
    self.generation=self.generation+1;local generation=self.generation
    local dialog=require('ui/widget/confirmbox'):new{text='正在查找 WIFI 网络…',ok_text='停止查找',cancel_text='关闭',
        ok_callback=function() self:cancel() end,cancel_callback=function() self:cancel() end}
    dialog.onSuspend=function() self:cancel();return true end
    dialog.onCloseWidget=function() if self.dialog==dialog then self:cancel() end end
    self.dialog=dialog;self.ui:show(dialog)
    local function done(result,err)
        if self.generation~=generation then return end
        self.dialog=nil;self.ui:close(dialog)
        if not result then
            self.ui:show(require('ui/widget/infomessage'):new{text='WIFI 查找失败，请重试。\n[wifi.scan] '..tostring(err and err.kind or 'network')})
            return
        end
        local list=result.networks
        self.network.is_wifi_on=result.wifi_on
        self.network.is_connected=result.connected
        table.sort(list,function(a,b) return (a.signal_quality or 0)>(b.signal_quality or 0) end)
        local picker=require('ui/widget/networksetting'):new{network_list=list,
            connect_callback=function() if self.generation==generation then self.network:scheduleConnectivityCheck() end end}
        self.picker=picker
        local closed=picker.onCloseWidget
        picker.onCloseWidget=function(widget)
            if self.picker==widget then self.picker=nil end
            if closed then closed(widget) end
        end
        picker.onSuspend=function() self:cancel();return true end
        self.ui:show(picker)
        -- The host owns association, password storage and lease handling.
        -- Observe automatic reconnection only if the scan reports a connection.
        for _,item in ipairs(list) do
            if item.connected then self.network:scheduleConnectivityCheck();break end
        end
    end
    local started,err=self.worker:start(function()
        local list,reason=self.network:getNetworkList()
        if not list then return nil,{kind=type(reason)=='string' and reason or 'scan_failed'} end
        while #list>256 do table.remove(list) end
        self.network:queryNetworkState()
        return {networks=list,wifi_on=self.network.is_wifi_on,connected=self.network.is_connected}
    end,done,25)
    if not started then done(nil,err) end
    return true
end
return W

describe('welite bounded WIFI scanner',function()
    local W
    setup(function() require('commonrequire');package.path='plugins/welite.koplugin/?.lua;'..package.path;W=require('weread.ui.welite.wifi') end)
    it('runs one scan off the UI callback and ignores cancelled late results',function()
        local task,finish,timeout,shown,cancelled
        local ui={show=function(_,w) shown=w end,close=function() end}
        local scans=0
        local w=W.new{ui=ui,network={getNetworkList=function() scans=scans+1;return {} end,queryNetworkState=function() end},worker={
            start=function(_,a,b,c) task,finish,timeout=a,b,c;return true end,cancel=function() cancelled=true end}}
        assert.is_true(w:scan());assert.equals(0,scans);assert.equals(25,timeout)
        assert.is_false(w:scan());assert.same({},task().networks);assert.equals(1,scans)
        local before=shown;shown:onSuspend();assert.is_true(cancelled);assert.is_nil(w.dialog)
        finish({{ssid='late'}});assert.equals(before,shown)
    end)
    it('caps scan results and updates host caches before showing the native picker',function()
        local task,finish,shown
        local n={getNetworkList=function()
            local list={};for i=1,300 do list[i]={ssid='test-'..i,signal_quality=i%100,flags='',signal_level='50',connected=false} end
            return list
        end,queryNetworkState=function(self) self.is_wifi_on=true;self.is_connected=false end}
        local w=W.new{ui={show=function(_,v) shown=v end,close=function() end},network=n,worker={
            start=function(_,a,b) task,finish=a,b;return true end,cancel=function() end}}
        w:scan();local result=task();assert.equals(256,#result.networks)
        finish(result);assert.is_nil(w.dialog);assert.equals(shown,w.picker)
        assert.is_true(n.is_wifi_on);assert.is_false(n.is_connected)
        w:cancel();assert.is_nil(w.picker)
    end)
    it('reports timeout and allows a fresh explicit retry',function()
        local finish,shown
        local w=W.new{ui={show=function(_,v) shown=v end,close=function() end},network={},worker={
            start=function(_,a,b) finish=b;return true end,cancel=function() end}}
        w:scan();finish(nil,{kind='timeout'});assert.is_nil(w.dialog)
        assert.is_truthy(shown.text:find('wifi.scan',1,true));assert.is_truthy(shown.text:find('timeout',1,true))
        assert.is_true(w:scan());w:cancel()
    end)
end)

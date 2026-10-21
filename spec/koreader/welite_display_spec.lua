describe('welite display formatting',function()
    local D
    setup(function() require('commonrequire');package.path='plugins/weread.koplugin/?.lua;'..package.path;D=require('weread.ui.welite.display') end)
    it('fits real font widths for long durations without changing neighboring columns',function()
        local width=require('device').screen:scaleBySize(166)
        for _,hours in ipairs({2,1000,10000,100000,100000000}) do
            local value=D.duration(hours*3600+3540,width,D.measure)
            assert.is_true(value.size>=18);assert.is_true(D.measure(value.text,value.size)<=width)
        end
        assert.equals('—',D.duration(nil,width,D.measure).text)
        assert.equals('0 分钟',D.duration(0,width,D.measure).text)
    end)
    it('uses cached network state and distinguishes unsupported battery information',function()
        local device={hasWifiToggle=function() return true end,hasBattery=function() return true end,
            getPowerDevice=function() return {getCapacity=function() return 88 end} end}
        local network={is_connected=true,isConnected=function() error('must not probe network') end}
        local status=D.status(device,network,100)
        assert.equals('WIFI已连接',status.wifi);assert.equals('88%',status.battery)
        network.is_connected=false;assert.equals('WIFI未连接',D.status(device,network,100).wifi)
        device.hasBattery=function() return false end;device.hasWifiToggle=function() return false end
        status=D.status(device,network,100);assert.equals('—',status.battery);assert.equals('WIFI —',status.wifi)
    end)
end)

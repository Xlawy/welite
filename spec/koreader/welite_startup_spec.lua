describe('welite once-per-process startup',function()
    setup(function() require('commonrequire');package.path='plugins/weread.koplugin/?.lua;'..package.path end)
    it('defers first-install choice and opens only when accepted',function()
        local gate=require('weread.ui.welite.startup').new();local queued,answer,opened
        opened=0
        local scheduler={nextTick=function(_,task) queued=task end}
        gate:queue(scheduler,function() return {decided=false} end,function(open) answer=open end,function() opened=opened+1 end)
        assert.is_nil(answer);queued();assert.equals(0,opened);answer();assert.equals(1,opened)
        assert.is_nil(gate:queue(scheduler,function() error('second host must not prompt') end))
    end)
    it('honors saved startup choices on a fresh process without prompting',function()
        for _,enabled in ipairs({false,true}) do
            local opened=0;local queued
            require('weread.ui.welite.startup').new():queue({nextTick=function(_,task) queued=task end},
                function() return {decided=true,autostart=enabled} end,
                function() error('already decided') end,function() opened=opened+1 end)
            queued();assert.equals(enabled and 1 or 0,opened)
        end
    end)
end)

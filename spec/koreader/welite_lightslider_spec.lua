describe('welite brightness slider',function()
    local S
    setup(function() require('commonrequire');package.path='plugins/welite.koplugin/?.lua;'..package.path;S=require('welite.ui.welite.lightslider') end)
    it('coalesces drag writes until release and consumes disabled gestures',function()
        local writes,preview=0,0
        local s=S:new{width=220,height=44,now=function() return 0 end,commit=function(v) writes=writes+1;assert.equals(100,v) end,preview=function() preview=preview+1 end}
        s.dimen.x=0
        for x=20,200,20 do s:onAdjust(nil,{ges='pan',pos={x=x}}) end
        assert.equals(0,writes);assert.equals(1,preview)
        s:onAdjust(nil,{ges='pan_release',pos={x=250}});assert.equals(1,writes)
        s.enabled=false;assert.is_true(s:onAdjust(nil,{ges='tap',pos={x=10}}));assert.equals(1,writes)
        s:free()
    end)
end)

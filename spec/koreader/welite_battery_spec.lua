describe('welite outlined battery',function()
    local Battery
    setup(function() require('commonrequire');package.path='plugins/welite.koplugin/?.lua;'..package.path;Battery=require('welite.ui.welite.battery') end)
    it('clamps charge and draws separated thin segments instead of a solid fill',function()
        local b=Battery:new{scale=1,percentage=0.78}
        assert.equals(4,b:segments())
        local rects={};local borders=0
        b:paintTo({paintRect=function(_,x,y,w,h) rects[#rects+1]={x,y,w,h} end,
            paintBorder=function() borders=borders+1 end},0,0)
        assert.equals(1,borders);assert.equals(6,#rects)
        for i=3,#rects do assert.equals(1,rects[i][3]);assert.equals(6,rects[i][4]) end
        for _,case in ipairs({{0,0},{0.01,1},{1,5},{2,5},{-1,0}}) do b.percentage=case[1];assert.equals(case[2],b:segments()) end
    end)
end)

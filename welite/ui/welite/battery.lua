-- Five thin charge segments, drawn directly with the host blitter (no image asset).
local Battery=require('ui/widget/widget'):extend{percentage=0}
function Battery:init()
    local scale=self.scale or 1
    self.unit=math.max(1,math.floor(scale+0.5))
    self.dimen=require('ui/geometry'):new{w=24*self.unit,h=12*self.unit}
end
function Battery:segments()
    local p=tonumber(self.percentage) or 0
    if p~=p or p<=0 then return 0 end
    return math.min(5,math.ceil(p*5))
end
function Battery:paintTo(bb,x,y)
    local B=require('ffi/blitbuffer');local u=self.unit
    x=math.floor(x);y=math.floor(y)
    bb:paintRect(x,y,24*u,12*u,B.COLOR_WHITE)
    bb:paintBorder(x,y,21*u,12*u,u,B.COLOR_BLACK)
    bb:paintRect(x+21*u,y+4*u,2*u,4*u,B.COLOR_BLACK)
    for i=1,self:segments() do bb:paintRect(x+(1+i*3)*u,y+3*u,u,6*u,B.COLOR_BLACK) end
end
return Battery

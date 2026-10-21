-- One native track; preview while dragging, at most one device write on release.
local Input=require('ui/widget/container/inputcontainer')
local Geom=require('ui/geometry')
local BB=require('ffi/blitbuffer')
local Slider=Input:extend{value=0,enabled=true}
function Slider:init()
    self.dimen=Geom:new{w=self.width,h=self.height}
    for _,name in ipairs({'tap','pan','pan_release','swipe'}) do
        self.ges_events[name]={require('ui/gesturerange'):new{ges=name,range=self.dimen},event='Adjust'}
    end
end
function Slider:getSize() return self.dimen end
function Slider:paintTo(bb,x,y)
    self.dimen.x=x;self.dimen.y=y
    local s=self.height/44;local inset=10*s;local width=self.width-2*inset
    bb:paintRect(x+inset,y+self.height/2,width,math.max(2,2*s),BB.COLOR_LIGHT_GRAY)
    bb:paintRect(x+inset,y+self.height/2,width*self.value/100,math.max(2,2*s),self.enabled and BB.COLOR_BLACK or BB.COLOR_DARK_GRAY)
    bb:paintRoundedRect(x+inset+width*self.value/100-7*s,y+self.height/2-10*s,14*s,22*s,BB.COLOR_BLACK,4*s)
    bb:paintRoundedRect(x+inset+width*self.value/100-6*s,y+self.height/2-9*s,12*s,20*s,BB.COLOR_WHITE,3*s)
end
function Slider:onAdjust(_,ges)
    if not self.enabled then return true end
    if ges.ges=='pan' and not self.dragging and ges.start_pos then
        local p=ges.start_pos;local d=self.dimen
        if p.x<d.x or p.x>d.x+d.w or p.y<d.y or p.y>d.y+d.h then return end
    end
    local pos=ges.pos
    if pos then
        local inset=10*self.height/44
        local x=(ges.ges=='swipe' and ges.end_pos and ges.end_pos.x) or pos.x
        self.value=math.floor(math.max(0,math.min(100,(x-self.dimen.x-inset)/(self.width-2*inset)*100))+0.5)
    end
    if ges.ges=='pan' then
        self.dragging=true
        local now=(self.now or require('socket').gettime)()
        if self.preview and (not self.last_preview or now-self.last_preview>=0.2) then
            self.last_preview=now;self.preview(self.value)
        end
    elseif ges.ges=='tap' or self.dragging or ges.ges=='swipe' then
        self.dragging=nil;self.last_preview=nil
        if self.commit then self.commit(self.value) end
    end
    return true
end
return Slider

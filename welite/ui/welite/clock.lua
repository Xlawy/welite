-- Fixed-width pairs with a smaller centered separator. Native fonts only.
local H=require('ui/widget/horizontalgroup')
local Text=require('ui/widget/textwidget')
local Center=require('ui/widget/container/centercontainer')
local Geom=require('ui/geometry')
local Font=require('ui/font')
local Clock=H:extend{align='center'}
function Clock:init()
    local face=Font:getFace('cfont',16)
    local probe=Text:new{text='00',face=face,bold=true,padding=0}
    local width,height=probe:getSize().w,probe:getSize().h;probe:free()
    self.hours=Text:new{text='00',face=face,bold=true,padding=0}
    self.minutes=Text:new{text='00',face=face,bold=true,padding=0}
    self.separator=Text:new{text=':',face=Font:getFace('cfont',13),padding=0}
    self[1]=Center:new{dimen=Geom:new{w=width,h=height},self.hours}
    self[2]=Center:new{dimen=Geom:new{w=math.ceil(height*.42),h=height},self.separator}
    self[3]=Center:new{dimen=Geom:new{w=width,h=height},self.minutes}
    self:setText(self.text or '00:00')
end
function Clock:setText(text)
    local hours,minutes=text:match('^(%d%d):(%d%d)$')
    self.hours:setText(hours or '--');self.minutes:setText(minutes or '--')
    self.text=text;self:resetLayout()
end
return Clock

-- Shared WeLite modal frame: heading, native scroll, focus, backdrop and close.
local BB=require('ffi/blitbuffer')
local Button=require('ui/widget/button')
local Device=require('device')
local Font=require('ui/font')
local Focus=require('ui/widget/focusmanager')
local Center=require('ui/widget/container/centercontainer')
local Frame=require('ui/widget/container/framecontainer')
local Geom=require('ui/geometry')
local H=require('ui/widget/horizontalgroup')
local HS=require('ui/widget/horizontalspan')
local Line=require('ui/widget/linewidget')
local Scroll=require('ui/widget/container/scrollablecontainer')
local Text=require('ui/widget/textwidget')
local UI=require('ui/uimanager')
local V=require('ui/widget/verticalgroup')
local VS=require('ui/widget/verticalspan')
local FocusNav=require('weread.ui.focus_nav')
local _=require('weread.lib.i18n').tr
local View=Focus:extend{modal=true}

function View:label(text,size,bold,width)
    return Text:new{text=text,face=Font:getFace('cfont',size),bold=bold,
        max_width=width or self.content_width,padding=0}
end
function View:space(height) return VS:new{width=self:px(height)} end
function View:px(value) return math.floor(value*self.scale+0.5) end
function View:line() return Line:new{dimen=Geom:new{w=self.content_width,h=1}} end
function View:button(text,width,callback,enabled,height)
    return Button:new{text=text,width=width,height=self:px(height or 42),padding=0,
        bordersize=1,radius=self:px(8),text_font_size=self.screen_w<400 and 13 or 16,
        text_font_bold=false,enabled=enabled~=false,show_parent=self,
        callback=function() if not self.closed and enabled~=false and callback then callback() end end}
end
function View:footer()
    self._footer_actions={}
    return self:space(12)
end
function View:toolbar() return self:space(0) end
function View:init()
    local screen=Device.screen
    local viewport_w,viewport_h=screen:getWidth(),screen:getHeight()
    self.scale=math.min(viewport_w,viewport_h)/600
    self.panel_height=math.floor(viewport_h*0.82)
    self.panel_border=math.max(1,self:px(2))
    self.screen_w=viewport_w-2*self:px(24)-2*self.panel_border
    self.screen_h=self.panel_height-2*self.panel_border
    self.outer_margin=self:px(24)
    self.content_width=self.screen_w-2*self.outer_margin
    self.dimen=Geom:new{x=0,y=0,w=viewport_w,h=viewport_h}
    self.covers_fullscreen=false
    self.ges_events.Outside={require('ui/gesturerange'):new{ges='tap',range=self.dimen}}
    self.key_events.Close={{Device.input.group.Back}}
    self._close_button=self:button(_('Back'),self:px(80),function() self:onClose() end)
    local head=H:new{require('ui/widget/container/leftcontainer'):new{dimen=Geom:new{w=self.content_width-self:px(80),h=self:px(44)},
        H:new{self:label('WeLite',21,true,self:px(100)),HS:new{width=self:px(16)},
            self:label(self.heading or '',18,false,self.content_width-self:px(196))}},self._close_button}
    self.header=Frame:new{padding_left=self.outer_margin,padding_right=self.outer_margin,
        padding_top=self.outer_margin,padding_bottom=0,bordersize=0,
        V:new{align='left',head,self:space(10),self:line()}}
    self._action_buttons={}
    local footer=self:footer()
    local toolbar=self:toolbar()
    self.scroll=Scroll:new{dimen=Geom:new{w=self.screen_w,h=self.screen_h-self.header:getSize().h-footer:getSize().h-toolbar:getSize().h},
        show_parent=self,H:new{HS:new{width=self.outer_margin},self:content()}}
    local rows={{self._close_button}}
    if self._title_button then rows[#rows+1]={self._title_button} end
    if self._toolbar_buttons and #self._toolbar_buttons>0 then rows[#rows+1]=self._toolbar_buttons end
    for _,button in ipairs(self._action_buttons) do rows[#rows+1]={button} end
    if self._footer_rows then
        for _,row in ipairs(self._footer_rows) do rows[#rows+1]=row end
    elseif #self._footer_actions>0 then rows[#rows+1]=self._footer_actions end
    local outside={[self._close_button]=true}
    for _,button in ipairs(self._footer_actions) do outside[button]=true end
    for _,button in ipairs(self._toolbar_buttons or {}) do outside[button]=true end
    FocusNav.apply(self,rows,{scroll=self.scroll,outside_scroll=outside})
    self.panel_frame=Frame:new{background=BB.COLOR_WHITE,bordersize=self.panel_border,padding=0,margin=0,radius=self:px(8),
        V:new{align='left',self.header,toolbar,self.scroll,footer}}
    self[1]=Center:new{dimen=self.dimen:copy(),self.panel_frame}
end
-- Opaque neutral backing makes the modal distinct on e-ink without allocating
-- a screenshot buffer, blurring, or repeatedly blending the existing framebuffer.
function View:paintTo(bb,x,y)
    bb:paintRect(x,y,self.dimen.w,self.dimen.h,BB.Color8(0xCC))
    Focus.paintTo(self,bb,x,y)
end
function View:onOutside(_,gesture)
    if not self.panel_frame.dimen:contains(gesture.pos) then self:onClose() end
    return true
end
function View:onShow() UI:setDirty(self,'ui');return true end
function View:onCloseWidget() self.closed=true;UI:setDirty(nil,'ui',self.dimen) end
function View:onClose() if not self.closed then self.closed=true;UI:close(self) end;return true end
return View

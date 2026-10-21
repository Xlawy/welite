-- WeLite book details: cached cover, bounded preview, native scrolling/actions.
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
local Box=require('ui/widget/textboxwidget')
local Text=require('ui/widget/textwidget')
local UI=require('ui/uimanager')
local V=require('ui/widget/verticalgroup')
local VS=require('ui/widget/verticalspan')
local FocusNav=require('weread.ui.focus_nav')
local _=require('weread.lib.i18n').tr
local View=Focus:extend{modal=true}

local function bounded(text,limit)
    text=tostring(text or '')
    if #text<=limit then return text end
    return text:sub(1,limit):gsub('[\194-\244][\128-\191]*$','')..'…'
end
function View:label(text,size,bold,width)
    return Text:new{text=text,face=Font:getFace('cfont',size),bold=bold,
        max_width=width or self.content_width,padding=0}
end
function View:space(height) return VS:new{width=self:px(height)} end
function View:px(value) return math.floor(value*self.scale+0.5) end
function View:line() return Line:new{dimen=Geom:new{w=self.content_width,h=1}} end
function View:button(text,width,callback,enabled)
    return Button:new{text=text,width=width,height=self:px(42),padding=0,
        bordersize=1,radius=self:px(8),text_font_size=self.screen_w<400 and 13 or 16,
        text_font_bold=false,enabled=enabled~=false,show_parent=self,
        callback=function() if not self.closed and enabled~=false and callback then callback() end end}
end
function View:section(title)
    return V:new{align='left',self:space(22),self:label(title,17,true),self:space(10)}
end
function View:showText(title,text)
    UI:show(require('ui/widget/textviewer'):new{title=title,text=text})
end
function View:hero()
    local cover_w,cover_h=self:px(100),self:px(150)
    local image
    if self.data.cover_path then
        image=require('ui/widget/imagewidget'):new{file=self.data.cover_path,width=cover_w,height=cover_h,
            file_do_cache=false,scale_factor=0,alpha=true}
    else
        image=Frame:new{padding=self:px(8),bordersize=1,background=BB.COLOR_WHITE,
            Center:new{dimen=Geom:new{w=cover_w-self:px(16)-2,h=cover_h-self:px(16)-2},
                Box:new{text=bounded(self.data.title,512),width=cover_w-self:px(20),height=cover_h-self:px(20),
                    height_adjust=true,height_overflow_show_ellipsis=true,alignment='center',face=Font:getFace('cfont',15)}}}
    end
    self.cover=image
    local text_w=self.content_width-cover_w-self:px(24)
    local title=Box:new{text=bounded(self.data.title,1024),face=Font:getFace('cfont',self.screen_w<400 and 22 or 28),
        bold=true,width=text_w,height=self:px(90),height_adjust=true,height_overflow_show_ellipsis=true}
    local author=Box:new{text=bounded(self.data.author_line,512),face=Font:getFace('cfont',15),
        width=text_w,height=self:px(40),height_adjust=true,height_overflow_show_ellipsis=true}
    self._title_button=Button:new{text='',width=text_w,height=cover_h,padding=0,bordersize=0,
        show_parent=self,callback=function()
            if not self.closed then self:showText(self.data.title,(self.data.title or '')..'\n\n'..(self.data.author_line or '')) end
        end}
    self._title_button.label_widget:free()
    self._title_button.label_container[1]=V:new{align='left',title,self:space(10),author}
    return H:new{align='top',Center:new{dimen=Geom:new{w=cover_w,h=cover_h},image},HS:new{width=self:px(24)},
        self._title_button}
end
function View:content()
    local body=V:new{align='left',HS:new{width=self.content_width},self:space(22),self:hero(),self:space(20),self:line(),self:space(14)}
    if #(self.data.metadata or {})>0 then
        body[#body+1]=self:section(_('Book information'))
        for index,item in ipairs(self.data.metadata) do
            if index>16 then break end
            local text=item.text or table.concat({item.left or '',item.right or ''},'    ')
            body[#body+1]=Box:new{text=bounded(text,1024),width=self.content_width,
                face=Font:getFace('cfont',15),height=self:px(60),height_adjust=true,height_overflow_show_ellipsis=true}
            body[#body+1]=self:space(10)
        end
    end
    local function add_action(action)
        local button=self:button(action.text,self.content_width,action.callback,action.enabled)
        self._action_buttons[#self._action_buttons+1]=button
        body[#body+1]=button;body[#body+1]=self:space(10)
    end
    body[#body+1]=self:space(22)
    for _,action in ipairs(self.data.actions or {}) do add_action(action) end
    body[#body+1]=self:space(24)
    return body
end
function View:footer()
    local actions=self.data.bottom_actions or {}
    local row=H:new{}
    local gap=self:px(10)
    local count=math.max(1,#actions)
    local width=math.floor((self.content_width-gap*(count-1))/count)
    self._footer_actions={}
    for index,action in ipairs(actions) do
        local button=self:button(action.text,width,action.callback,action.enabled)
        self._footer_actions[#self._footer_actions+1]=button
        row[#row+1]=button
        if index<#actions then row[#row+1]=HS:new{width=gap} end
    end
    return Frame:new{padding_left=self.outer_margin,padding_right=self.outer_margin,
        padding_top=self:px(12),padding_bottom=self:px(18),bordersize=0,
        V:new{align='left',self:line(),self:space(12),row}}
end
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
            self:label(_('Book details'),18,false,self.content_width-self:px(196))}},self._close_button}
    self.header=Frame:new{padding_left=self.outer_margin,padding_right=self.outer_margin,
        padding_top=self.outer_margin,padding_bottom=0,bordersize=0,
        V:new{align='left',head,self:space(10),self:line()}}
    self._action_buttons={}
    local footer=self:footer()
    self.scroll=Scroll:new{dimen=Geom:new{w=self.screen_w,h=self.screen_h-self.header:getSize().h-footer:getSize().h},
        show_parent=self,H:new{HS:new{width=self.outer_margin},self:content()}}
    local rows={{self._close_button},{self._title_button}}
    for _,button in ipairs(self._action_buttons) do rows[#rows+1]={button} end
    if #self._footer_actions>0 then rows[#rows+1]=self._footer_actions end
    local outside={[self._close_button]=true}
    for _,button in ipairs(self._footer_actions) do outside[button]=true end
    FocusNav.apply(self,rows,{scroll=self.scroll,outside_scroll=outside})
    self.panel_frame=Frame:new{background=BB.COLOR_WHITE,bordersize=self.panel_border,padding=0,margin=0,radius=self:px(8),
        V:new{align='left',self.header,self.scroll,footer}}
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
local M={}
function M.show(data,callbacks)
    local view=View:new{data=data,on_refresh=callbacks and callbacks.on_refresh}
    UI:show(view)
    return view
end
return M

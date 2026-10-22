-- WeLite book details: cached cover, bounded preview, native scrolling/actions.
local BB=require('ffi/blitbuffer')
local Button=require('ui/widget/button')
local Font=require('ui/font')
local Center=require('ui/widget/container/centercontainer')
local Frame=require('ui/widget/container/framecontainer')
local Geom=require('ui/geometry')
local H=require('ui/widget/horizontalgroup')
local HS=require('ui/widget/horizontalspan')
local Box=require('ui/widget/textboxwidget')
local UI=require('ui/uimanager')
local V=require('ui/widget/verticalgroup')
local _=require('welite.lib.i18n').tr
local View=require('welite.ui.welite.panel'):extend{}

local function bounded(text,limit)
    text=tostring(text or '')
    if #text<=limit then return text end
    return text:sub(1,limit):gsub('[\194-\244][\128-\191]*$','')..'…'
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
    if self.data.review_action then add_action(self.data.review_action) end
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
    self.heading=_('Book details')
    require('welite.ui.welite.panel').init(self)
end
local M={}
function View:onCloseWidget()
    require('welite.ui.welite.panel').onCloseWidget(self)
    if self.on_closed then self.on_closed() end
end
function M.show(data,callbacks,existing)
    local view=existing
    if view and not view.closed then
        view[1]:free()
        view.data=data
        view.on_refresh=callbacks and callbacks.on_refresh
        view.on_closed=callbacks and callbacks.on_close
        view:init()
        UI:setDirty(view,'ui')
    else
        view=View:new{data=data,on_refresh=callbacks and callbacks.on_refresh,
            on_closed=callbacks and callbacks.on_close}
        UI:show(view)
    end
    return view
end
return M

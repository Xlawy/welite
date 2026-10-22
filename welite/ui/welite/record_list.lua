-- Bounded WeLite record list shared by search and public-account views.
local Panel=require('welite.ui.welite.panel')
local Font=require('ui/font')
local V=require('ui/widget/verticalgroup')
local H=require('ui/widget/horizontalgroup')
local HS=require('ui/widget/horizontalspan')
local Box=require('ui/widget/textboxwidget')
local UI=require('ui/uimanager')
local _=require('welite.lib.i18n').tr
local View=Panel:extend{}
function View:init()
    self.page=math.max(1,math.min(self.page or 1,math.max(1,math.ceil(#self.items/10))))
    Panel.init(self)
end
function View:turn(delta)
    self.page=self.page+delta
    self[1]:free();self[1]=nil;self:init();UI:setDirty(self,'ui')
end
function View:content()
    local body=V:new{align='left',HS:new{width=self.content_width},self:space(14),
        self:label(self.caption or '',17,true),self:space(16)}
    self._item_buttons={}
    if self.status then
        body[#body+1]=Box:new{text=self.status,width=self.content_width,face=Font:getFace('cfont',15)}
        if self.on_retry then
            self._retry_button=self:button(_('Retry'),self.content_width,self.on_retry)
            body[#body+1]=self:space(16);body[#body+1]=self._retry_button
            self._action_buttons[#self._action_buttons+1]=self._retry_button
        end
    elseif #self.items==0 then
        body[#body+1]=self:label(self.empty_text,16,false)
    else
        for index=(self.page-1)*10+1,math.min(#self.items,self.page*10) do
            local book=self.items[index]
            local button=self:button('',self.content_width,function() if self.on_select then self.on_select(book) end end,true,84)
            button.label_widget:free()
            button.label_container[1]=V:new{align='left',
                self:label(book.title,18,true,self.content_width-self:px(24)),self:space(10),
                self:label(book.author,14,false,self.content_width-self:px(24))}
            self._item_buttons[#self._item_buttons+1]=button
            self._action_buttons[#self._action_buttons+1]=button
            body[#body+1]=button;body[#body+1]=self:space(12)
        end
    end
    body[#body+1]=self:space(12)
    return body
end
function View:footer()
    local body=V:new{align='left',self:space(12)}
    self._footer_actions={}
    self._footer_rows={}
    local pages=math.max(1,math.ceil(#self.items/10))
    if pages>1 then
        local width=math.floor((self.content_width-self:px(80))/2)
        self._previous_button=self:button(_('Previous page'),width,function() self:turn(-1) end,self.page>1)
        self._next_button=self:button(_('Next page'),width,function() self:turn(1) end,self.page<pages)
        self._footer_actions={self._previous_button,self._next_button}
        self._footer_rows[1]={self._previous_button,self._next_button}
        body[#body+1]=H:new{HS:new{width=self.outer_margin},self._previous_button,
            require('ui/widget/container/centercontainer'):new{dimen=require('ui/geometry'):new{w=self:px(80),h=self:px(42)},
                self:label(self.page..' / '..pages,14,false)},self._next_button}
        body[#body+1]=self:space(10)
    end
    self._batch_buttons={}
    for _,action in ipairs(self.batch_actions or {}) do
        local button=self:button(action.text,self.content_width,action.callback)
        self._batch_buttons[#self._batch_buttons+1]=button
        self._footer_actions[#self._footer_actions+1]=button
        self._footer_rows[#self._footer_rows+1]={button}
        body[#body+1]=H:new{HS:new{width=self.outer_margin},button}
        body[#body+1]=self:space(8)
    end
    self._action_button=self:button(self.action_text,self.content_width,function() if self.on_action then self.on_action() end end)
    self._footer_actions[#self._footer_actions+1]=self._action_button
    self._footer_rows[#self._footer_rows+1]={self._action_button}
    body[#body+1]=H:new{HS:new{width=self.outer_margin},self._action_button}
    body[#body+1]=self:space(12)
    return body
end
function View:onCloseWidget()
    Panel.onCloseWidget(self)
    if self.on_close then self.on_close() end
end
local M={}
function M.show(data,callbacks)
    local view=View:new{heading=data.heading,caption=data.caption,empty_text=data.empty_text or _('No items.'),
        batch_actions=data.batch_actions,action_text=data.action_text or _('Back'),items=data.items or {},status=data.status,
        on_select=callbacks.on_select,on_retry=callbacks.on_retry,on_action=callbacks.on_action,on_close=callbacks.on_close}
    UI:show(view);return view
end
return M

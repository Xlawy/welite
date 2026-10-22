-- WeLite review list and detail; data loading remains in the controller.
local Panel=require('weread.ui.welite.panel')
local Font=require('ui/font')
local Frame=require('ui/widget/container/framecontainer')
local H=require('ui/widget/horizontalgroup')
local HS=require('ui/widget/horizontalspan')
local Box=require('ui/widget/textboxwidget')
local V=require('ui/widget/verticalgroup')
local UI=require('ui/uimanager')
local Reviews=require('weread.lib.book_reviews')
local _=require('weread.lib.i18n').tr
local T=require('ffi/util').template
local View=Panel:extend{}
local tabs={{mode='recommended',text='Recommended reviews'},{mode='latest',text='Latest reviews'}}

-- Reuse the packaged thought-popup fallback chain, including NotoEmoji.
-- Only review text needs it; face construction is cached by size.
local function contentFace(view,size)
    local faces=require('weread.ui.thought_popup.face_factory')
    faces:findEmojiFont()
    return faces:getFace(nil,view:px(size),'ui') or Font:getFace('cfont',size)
end

local function metadata(review)
    local parts={review.author~='' and review.author or _('Anonymous')}
    if review.rating>0 then parts[#parts+1]=T(_('Score %1'),Reviews.format_rating(review.rating)) end
    local date=Reviews.format_date(review.create_time)
    if date~='' then parts[#parts+1]=date end
    if review.is_finish then parts[#parts+1]=_('Finished') end
    return table.concat(parts,' · ')
end
function View:toolbar()
    local row=H:new{}
    self._tab_buttons={};self._toolbar_buttons=self._tab_buttons
    local gap=self:px(10);local width=math.floor((self.content_width-gap)/2)
    for i,tab in ipairs(tabs) do
        local selected=tab.mode==self.mode
        local button=self:button(_(tab.text),width,function()
            if not selected and self.on_switch then self.on_switch(tab.mode) end
        end)
        -- Keep selection visible independently of the keyboard focus cursor.
        button.frame.bordersize=selected and self:px(2) or 1
        button.dimen.h=button.frame:getSize().h
        self._tab_buttons[i]=button;row[#row+1]=button
        if i==1 then row[#row+1]=HS:new{width=gap} end
    end
    return Frame:new{padding_left=self.outer_margin,padding_right=self.outer_margin,
        padding_top=self:px(14),padding_bottom=self:px(10),bordersize=0,row}
end
function View:content()
    local body=V:new{align='left',HS:new{width=self.content_width},self:space(14),
        self:label(self.book_title or _('Untitled'),18,true),self:space(16)}
    self._review_buttons={}
    if self.status then
        body[#body+1]=Box:new{text=self.status,width=self.content_width,face=Font:getFace('cfont',15)}
        if self.on_retry then
            local button=self:button(_('Retry'),self.content_width,self.on_retry)
            self._action_buttons[#self._action_buttons+1]=button
            body[#body+1]=self:space(16);body[#body+1]=button
            self._retry_button=button
        end
    elseif #(self.result and self.result.items or {})==0 then
        body[#body+1]=self:label(_('No reviews.'),16,false)
    else
        for _,review in ipairs(self.result.items) do
            local button=self:button('',self.content_width,function()
                if self.on_select then self.on_select(review,self.mode) end
            end,true,108)
            button.label_widget:free()
            button.label_container[1]=V:new{align='left',
                self:label(metadata(review),14,true,self.content_width-self:px(24)),self:space(8),
                Box:new{text=Reviews.preview(review.content~='' and review.content or _('No review content.'),90),
                    width=self.content_width-self:px(24),height=self:px(65),height_adjust=true,
                    height_overflow_show_ellipsis=true,face=contentFace(self,15)}}
            self._review_buttons[#self._review_buttons+1]=button
            self._action_buttons[#self._action_buttons+1]=button
            body[#body+1]=button;body[#body+1]=self:space(12)
        end
    end
    body[#body+1]=self:space(12)
    return body
end
function View:init() self.heading=_('Book reviews');Panel.init(self) end
function View:onCloseWidget()
    Panel.onCloseWidget(self)
    if self.on_close then self.on_close() end
end
local Detail=Panel:extend{}
function Detail:init() self.heading=_('Book reviews');Panel.init(self) end
function Detail:content()
    return V:new{align='left',HS:new{width=self.content_width},self:space(18),
        self:label(self.book_title or _('Untitled'),18,true),self:space(12),
        self:label(metadata(self.review),14,false),self:space(18),self:line(),self:space(18),
        Box:new{text=self.review.content~='' and self.review.content or _('No review content.'),
            width=self.content_width,face=contentFace(self,16)},self:space(18)}
end
local M={}
function M.show(data,callbacks)
    callbacks=callbacks or {}
    local view=View:new{book_title=data.book_title,mode=data.mode or 'recommended',result=data.result,
        status=data.status,on_switch=callbacks.on_switch,on_select=callbacks.on_select,
        on_retry=callbacks.on_retry,on_close=callbacks.on_close}
    UI:show(view);return view
end
function M.showDetail(book,review)
    local view=Detail:new{book_title=book.title,review=review}
    UI:show(view);return view
end
return M

-- Shared bounded native menu; constructed only when opened, no network in paint.
local Focus=require('ui/widget/focusmanager')
local Button=require('ui/widget/button')
local Text=require('ui/widget/textwidget')
local Font=require('ui/font')
local Frame=require('ui/widget/container/framecontainer')
local Center=require('ui/widget/container/centercontainer')
local V=require('ui/widget/verticalgroup')
local H=require('ui/widget/horizontalgroup')
local VS=require('ui/widget/verticalspan')
local HS=require('ui/widget/horizontalspan')
local Geom=require('ui/geometry')
local BB=require('ffi/blitbuffer')
local Device=require('device')
local UI=require('ui/uimanager')
local Panel=Focus:extend{modal=true}
function Panel:init()
    self.controls=self.controls or require('weread.ui.welite.controls').new(self.host)
    self.key_events.Close={{Device.input.group.Back},{'Menu'}}
    for _,g in ipairs({'tap','swipe'}) do
        self.ges_events[g]={require('ui/gesturerange'):new{ges=g,range=Device.screen:getSize()},event=g=='tap' and 'Outside' or 'Swipe'}
    end
    for _,g in ipairs({'pan','pan_release'}) do
        self.ges_events[g]={require('ui/gesturerange'):new{ges=g,range=Device.screen:getSize()},event='SliderDrag'}
    end
    self:build()
end
function Panel:build()
    if self[1] then self[1]:free() end
    local w,h=Device.screen:getWidth(),Device.screen:getHeight()
    local s=math.min(w,h)/600
    -- Keep stacked frame/child extents on whole pixels: fractional heights can
    -- let the following footer background overwrite a one-pixel bottom border.
    local function px(value) return math.floor(value*s+0.5) end
    local pad=px(24);local width=w-2*pad
    self.dimen=Geom:new{x=0,y=0,w=w,h=h};self.layout={};self.buttons={}
    local state=self.controls:snapshot();self.state=state
    local function label(t,size,bold,max)
        return Text:new{text=t,face=Font:getFace('cfont',size),bold=bold,max_width=max or width,padding=0}
    end
    local function slot(widget,bw,bh,align)
        return require('ui/widget/container/'..(align or 'center')..'container'):new{dimen=Geom:new{w=math.floor(bw+0.5),h=math.floor(bh+0.5)},widget}
    end
    local function button(t,bw,bh,cb,enabled,size,border)
        return Button:new{text=t,width=math.floor(bw+0.5),height=math.floor(bh+0.5),padding=0,bordersize=border or 0,radius=px(10),
            text_font_size=size or 16,text_font_bold=false,callback=cb,enabled=enabled~=false,show_parent=self}
    end
    local function action(fn,close)
        return function()
            if self.closed then return end
            if close then self:onClose() end
            local ok,err=pcall(fn)
            if not ok or err==false then
                UI:show(require('ui/widget/infomessage'):new{text='操作未完成，请检查设备支持与当前状态。\n[controls] '..(not ok and tostring(err) or 'unsupported')})
            elseif not self.closed then self:rebuild() end
        end
    end
    local cell=math.floor(width/6)
    local sync=self.shelf and (self.shelf.refreshing and '同步中…' or self.shelf.sync_status or (self.shelf.updated and '已同步' or '未同步')) or self.sync_status or '未同步'
    -- The caller supplies the actual shelf/reader status.
    self.sync_button=button(sync,cell,px(44),function()
        self:onClose();if self.sync then self.sync() end
    end,self.sync~=nil and not (self.shelf and self.shelf.refreshing),15)
    local logged_in=self.shelf and self.shelf.logged_in or (not self.shelf and self.auth_view and self.auth_view.logged_in)
    self.login_button=button((logged_in and '已登录' or '未登录'),cell,px(44),function()
        self:onClose();if self.login then self.login() end
    end,self.login~=nil,15)
    self.clock=require('weread.ui.welite.clock'):new{text=state.time};self.wifi=label(state.wifi,15,false,cell)
    self.battery_bar=require('weread.ui.welite.battery'):new{scale=s,percentage=(state.capacity or 0)/100}
    self.battery_text=label(state.battery,15)
    self.battery=H:new{self.battery_bar,HS:new{width=px(5)},self.battery_text}
    local head=H:new{slot(label('WeLite',21,true,cell),cell,px(44),'left'),self.login_button,slot(self.wifi,cell,px(44)),self.sync_button,
        slot(self.clock,cell,px(44)),slot(self.battery,width-5*cell,px(44),'right')}
    self.layout[#self.layout+1]={self.login_button,self.sync_button}
    local body=V:new{align='left'}
    -- The bookshelf may be opened over a live ReaderUI. Its panel is still
    -- a home panel, regardless of whether the host retains an open document.
    self.reading_info,self.home_button,self.chapter_buttons=nil,nil,nil
    local info=not self.shelf and require('weread.ui.welite.controls').reading(self.host,self.result)
    if info then
        self.reading_info=info
        local title=button('',width-px(112),px(44),function()
            UI:show(require('ui/widget/infomessage'):new{text=info.title..'\n'..info.chapter})
        end,true,20)
        title.label_widget:free()
        title.label_container[1]=slot(label(info.title,20,true,width-px(120)),width-px(112),px(44),'left')
        self.home_button=button('返回首页',px(104),px(40),action(function() self.home() end,true),self.home~=nil,15,1)
        body[#body+1]=H:new{title,HS:new{width=px(8)},self.home_button}
        body[#body+1]=H:new{slot(label(info.chapter,14,false,width*.38),width*.38,px(30),'left'),slot(label(info.percent..' · '..info.pages,14,false,width*.62),width*.62,px(30),'right')}
        self.layout[#self.layout+1]={title,self.home_button}
        if self.chapters then
            local bw=(width-px(16))/3
            self.chapter_buttons={}
            for i,entry in ipairs({{'‹ 上一章','previous'},{'章节跳转','catalog'},{'下一章 ›','next'}}) do
                local callback=self.chapters[entry[2]]
                self.chapter_buttons[i]=button(entry[1],bw,px(40),callback and action(callback,true),callback~=nil,14,1)
            end
            body[#body+1]=VS:new{width=px(6)}
            body[#body+1]=H:new{self.chapter_buttons[1],HS:new{width=px(8)},self.chapter_buttons[2],HS:new{width=px(8)},self.chapter_buttons[3]}
            self.layout[#self.layout+1]=self.chapter_buttons
        end
        if self.annotations then
            self.annotations_button=button('划线和想法',width,px(40),action(self.annotations,true),true,14,1)
            body[#body+1]=VS:new{width=px(8)}
            body[#body+1]=self.annotations_button
            self.layout[#self.layout+1]={self.annotations_button}
        end
        body[#body+1]=VS:new{width=px(12)}
    end
    local gap=px(8)
    local columns=5
    local bw=math.floor((width-gap*(columns-1))/columns)
    local definitions={
        {'WIFI','wifi',state.wifi_supported and state.network or '设备不支持',action(function() return self.controls:wifi(true) end,true)},
        {'夜间模式','moon',state.night and '已开启' or '已关闭',action(function() self.controls:night() end)},
        {'全屏刷新','refresh','清除残影',function() if not self.closed then self:onClose();self.controls:refresh() end end},
        {'KO 设置','settings','打开设置 ›',action(function() return self.controls:settingsMenu() end,true)},
        {'WeLite 设置','settings','时间与启动 ›',action(function() return self.controls:weliteSettings() end,true)},
    }
    local cardpad=px(6)
    local inner=bw-2*cardpad-2
    local togglewidth=math.min(px(44),math.floor(inner*.52))
    local function fitted(text,size,bold)
        while size>8 and require('weread.ui.welite.display').measure(text,size)>inner do size=size-1 end
        return label(text,size,bold,inner)
    end
    self.action_titles={}
    for start=1,#definitions,columns do
        local row=H:new{align='top'};local focus={}
        for i=start,math.min(#definitions,start+columns-1) do
            local def=definitions[i];local enabled=def[4]~=nil and (i~=1 or state.wifi_supported)
            local iconsize=math.min(px(24),inner-togglewidth-px(2))
            local icon=require('weread.ui.welite.controlicon'):new{kind=def[2],width=iconsize,height=iconsize}
            local top
            if i==1 then
                self.wifi_toggle=button(state.wifi_on and '开' or '关',togglewidth,px(44),action(function() return self.controls:wifi(false) end,true),state.wifi_supported,13)
                self.wifi_toggle.label_widget:free()
                self.wifi_toggle.label_container[1]=slot(require('weread.ui.welite.controlicon'):new{kind='toggle',on=state.wifi_on,width=togglewidth,height=math.floor(togglewidth*.55)},togglewidth,px(44))
                top=H:new{slot(icon,inner-togglewidth,px(44),'left'),self.wifi_toggle}
                focus[#focus+1]=self.wifi_toggle
            else top=slot(icon,inner,px(44),'left') end
            local select=button('',inner,px(48),def[4],enabled,16)
            select.label_widget:free()
            local title=fitted(def[1],16,true);self.action_titles[i]=title
            select.label_container[1]=V:new{align='left',title,fitted(def[3],12,false)}
            local contents=V:new{align='left',top,select}
            local card=Frame:new{padding_left=cardpad,padding_right=cardpad,padding_top=0,padding_bottom=px(4),
                bordersize=1,radius=px(10),background=BB.COLOR_WHITE,dim=not enabled,contents}
            if def[2]=='moon' and state.night then card.invert=true end
            -- Non-radio cards accept a tap anywhere, including the icon.
            if i~=1 then
                local outer=button('',bw,px(102),def[4],enabled)
                outer.label_widget:free();outer.label_container[1]=card;row[#row+1]=outer
                self.buttons[i]=outer;focus[#focus+1]=outer
            else row[#row+1]=card;self.buttons[i]=select;focus[#focus+1]=select end
            if i<math.min(#definitions,start+columns-1) then row[#row+1]=HS:new{width=gap} end
        end
        body[#body+1]=row;body[#body+1]=VS:new{width=px(12)};self.layout[#self.layout+1]=focus
    end
    local lightwidth=width-px(24)-2
    self.light_toggle=button(state.light_supported and (state.light_on and '开' or '关') or '—',px(44),px(44),
        action(function() return self.controls:light() end),state.light_supported,14)
    if state.light_supported then
        self.light_toggle.label_widget:free()
        self.light_toggle.label_container[1]=slot(require('weread.ui.welite.controlicon'):new{kind='toggle',on=state.light_on,width=togglewidth,height=math.floor(togglewidth*.55)},togglewidth,px(44))
    end
    self.brightness=label(state.light_supported and ((state.brightness or 0)..'%') or '设备不支持',15,true)
    local lighthead=H:new{slot(label('背光亮度',17,true),lightwidth*.50,px(44),'left'),
        slot(self.brightness,lightwidth*.50-px(50),px(44),'right'),HS:new{width=px(6)},self.light_toggle}
    local enabled=state.light_supported and state.light_on
    local function set(value) return action(function() return self.controls:brightness(value) end)() end
    self.minus=button('−',px(44),px(44),action(function() return self.controls:step(-1) end),enabled,22,1)
    self.plus=button('+',px(44),px(44),action(function() return self.controls:step(1) end),enabled,22,1)
    self.slider=require('weread.ui.welite.lightslider'):new{width=lightwidth-px(104),height=px(44),value=state.brightness or 0,enabled=enabled,
        preview=function(value)
            self.brightness:setText(value..'%');UI:setDirty(self,'ui',self.light_region)
        end,commit=set}
    self.light_box=Frame:new{padding=px(12),padding_top=0,padding_bottom=px(8),bordersize=1,radius=px(10),
        V:new{lighthead,H:new{self.minus,HS:new{width=px(8)},self.slider,HS:new{width=px(8)},self.plus}}}
    body[#body+1]=self.light_box
    self.layout[#self.layout+1]={self.light_toggle,self.minus,self.plus}
    self.close_button=button('上滑收起',width,px(44),function() self:onClose() end,true,12)
    self.layout[#self.layout+1]={self.close_button}
    local content_h=body:getSize().h;local viewport=math.min(content_h,h-2*pad-px(44)-px(44)-px(14))
    local content=body
    if viewport<content_h then
        self.cropping_widget=require('ui/widget/container/scrollablecontainer'):new{dimen=Geom:new{w=width,h=viewport},body}
        content=self.cropping_widget
    else self.cropping_widget=nil end
    self[1]=Frame:new{padding=pad,padding_top=pad,padding_bottom=0,bordersize=0,background=BB.COLOR_WHITE,
        V:new{align='left',head,require('ui/widget/linewidget'):new{dimen=Geom:new{w=width,h=1}},VS:new{width=px(12)},content,self.close_button}}
    self.panel_height=self[1]:getSize().h
    self.selected={x=1,y=1};self:refocusWidget()
end
function Panel:paintTo(bb,x,y)
    Focus.paintTo(self,bb,x,y)
    if self.light_box then self.light_region=self.light_box.dimen end
end
function Panel:rebuild() if not self.closed then self:build();UI:setDirty(self,'ui') end end
function Panel:onOutside(_,ges)
    if ges.pos.y>=self.panel_height then self:onClose() end
    return true
end
function Panel:onSwipe(_,ges)
    if self.slider and self.slider.dragging then return self.slider:onAdjust(nil,ges) end
    if ges.direction=='north' then self:onClose() end
    return true
end
function Panel:onSliderDrag(_,ges)
    if self.slider and self.slider.dragging then return self.slider:onAdjust(nil,ges) end
    return true
end
function Panel:updateStatus()
    local state=self.controls:snapshot()
    self.clock:setText(state.time);self.wifi:setText(state.wifi)
    self.battery_text:setText(state.battery);self.battery_bar.percentage=(state.capacity or 0)/100
    self.battery:resetLayout()
    UI:setDirty(self,'ui',Geom:new{x=0,y=0,w=self.dimen.w,h=68*math.min(self.dimen.w,self.dimen.h)/600})
end
function Panel:onShow()
    self.timer=function()
        if self.closed then return end
        if UI:getTopmostVisibleWidget()==self then self:updateStatus() end
        UI:scheduleIn(60-tonumber(os.date('%S')),self.timer)
    end
    UI:scheduleIn(60-tonumber(os.date('%S')),self.timer);UI:setDirty(self,'ui');return true
end
function Panel:onClose()
    if self.closed then return true end
    self.closed=true;UI:close(self);return true
end
function Panel:onCloseWidget()
    self.closed=true
    if self.timer then UI:unschedule(self.timer);self.timer=nil end
    if self.close_callback then self.close_callback();self.close_callback=nil end
    UI:setDirty('all','ui')
end
Panel.onNetworkConnected=Panel.rebuild
Panel.onNetworkDisconnected=Panel.rebuild
Panel.onSuspend=Panel.onClose
Panel.onSetDimensions=Panel.onClose
return Panel

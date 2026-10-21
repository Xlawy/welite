-- A bounded native widget tree: at most six book cards and their thumbnails.
local FocusManager=require("ui/widget/focusmanager")
local Button=require("ui/widget/button")
local Text=require("ui/widget/textwidget")
local Box=require("ui/widget/textboxwidget")
local Vertical=require("ui/widget/verticalgroup")
local Horizontal=require("ui/widget/horizontalgroup")
local Center=require("ui/widget/container/centercontainer")
local Frame=require("ui/widget/container/framecontainer")
local Span=require("ui/widget/verticalspan")
local Geom=require("ui/geometry")
local Font=require("ui/font")
local Device=require("device")
local UI=require("ui/uimanager")
local Reading=require("welite/reading")
local Shelf=FocusManager:extend{page=1,query="",category="shelf",sort="cloud",fullscreen=true}
function Shelf.coverErrorText(err)
    if not err then return nil end
    if err.kind=="cover_pixels" then return "封面像素超限" end
    return "封面加载失败"
end
function Shelf.progressText(item)
    local percent=Reading.number(item.percent,100)
    return percent and (math.floor(percent).."%") or "—"
end
function Shelf:init()
    self.cover_paths=self.cover_paths or {}
    self.key_events.Close={{Device.input.group.Back}}
    self.key_events.QuickMenu={{"Menu"}}
    self.key_events.NextPage={{"PageForward"}}
    self.key_events.PreviousPage={{"PageBack"}}
    self.ges_events.Swipe={require("ui/gesturerange"):new{ges="swipe",range=Device.screen:getSize()}}
    for _,g in ipairs({'pan','pan_release'}) do
        self.ges_events[g]={require('ui/gesturerange'):new{ges=g,range=Device.screen:getSize()},event='PullDrag'}
    end
    self:build()
end
function Shelf:onPullDrag(_,gesture)
    if gesture.ges=='pan' then
        self.pulldown_drag=gesture.start_pos and gesture.start_pos.y<=Device.screen:getHeight()*.12 and gesture.direction=='south'
        return self.pulldown_drag
    elseif self.pulldown_drag then
        self.pulldown_drag=nil;return self:onQuickMenu()
    end
end
function Shelf:filtered()
    if not self.filtered_items then
        self.filtered_items=require("welite/collection").select(self.items,self.local_items,self.downloads or {},self.category,self.sort,self.query,self.download_filter)
    end
    return self.filtered_items
end
function Shelf:visibleItems() return self.visible or {} end
function Shelf:build()
    if self[1] then self[1]:free();self[1]=nil end
    local screen=Device.screen
    local w,h=screen:getWidth(),screen:getHeight()
    local s=math.min(w,h)/600
    local pad=math.floor(24*s);local width=w-2*pad
    local function label(text,size,bold)
        return Text:new{text=text,face=Font:getFace("cfont",size),bold=bold,max_width=width,padding=0}
    end
    local function button(text,bw,callback,enabled)
        return Button:new{text=text,width=bw,height=math.floor(36*s),padding=math.floor(4*s),
            bordersize=0,text_font_size=17,text_font_bold=false,callback=callback,enabled=enabled~=false}
    end
    local actions=self.actions
    local Display=require("welite/display")
    local status=Display.status(Device,require("ui/network/manager"))
    local function line(w,thickness)
        return require("ui/widget/linewidget"):new{dimen=Geom:new{w=w,h=math.max(1,math.floor(thickness*s))}}
    end
    local function slot(widget,bw,bh,align)
        local name=align=="left" and "leftcontainer" or align=="right" and "rightcontainer" or "centercontainer"
        return require("ui/widget/container/"..name):new{dimen=Geom:new{w=bw,h=bh},widget}
    end
    local function textbutton(text,bw,callback,size,align,bh)
        bh=bh or 44*s
        local b=Button:new{text=text,width=bw,height=bh,padding=0,bordersize=0,
            text_font_size=size,text_font_bold=text=="WeLite",align=align or "center",callback=callback}
        if align=="right" then b.label_container[1]=slot(b.label_widget,bw,bh,"right") end
        return b
    end
    local cell=math.floor(width/6)
    self.brand=textbutton("WeLite",cell,actions.more,21,"left")
    self.login_button=textbutton(require("config/messages").login[self.logged_in and "connected" or "disconnected"],cell,actions.login,15)
    self.wifi_label=label(status.wifi,15,false)
    local sync_text=self.sync_status=="同步冲突" and "同步冲突" or self.refreshing and "同步中…" or self.sync_status or (self.updated and "已同步" or "未同步")
    self.sync_button=textbutton(require("config/messages").status[sync_text] or sync_text,cell,actions.status or actions.refresh,15)
    self.sync_button:enableDisable(not self.refreshing)
    self.clock_label=require('welite/clock'):new{text=status.time}
    self.battery_label=label(status.battery,15,false)
    self.battery_bar=require("welite/battery"):new{scale=s,percentage=(status.capacity or 0)/100}
    local battery=Horizontal:new{align="center",self.battery_bar,require("ui/widget/horizontalspan"):new{width=5*s},self.battery_label}
    self.battery_group=battery
    local head=Horizontal:new{align="center",self.brand,self.login_button,slot(self.wifi_label,cell,44*s),self.sync_button,
        slot(self.clock_label,cell,44*s),slot(battery,width-5*cell,44*s,"right")}
    self.toolbar={self.sync_button,self.brand}
    self.status_region=Geom:new{x=pad,y=pad,w=width,h=44*s}
    self.last_status=status
    self.day_stamp=Reading.dayStart(os.time())
    local stats=Horizontal:new{align="center"};self.stat_buttons={};self.stat_values={}
    self.duration_cache=self.duration_cache or {}
    for i,period in ipairs({"monthly","weekly","daily"}) do
        local bw=math.floor(width/3);local stat=period=="daily" and Reading.today(self.overview) or (self.overview or {})[period]
        if not stat and (self.mode or "monthly")==period then stat=self.statistics end
        local seconds=stat and stat.total_seconds
        local key=tostring(seconds)..":"..bw..":"..Font:getFace("cfont",23).size
        local cached=self.duration_cache[period]
        local fitted=cached and cached.key==key and cached.value
        if not fitted then fitted=Display.duration(seconds,bw-16*s,Display.measure);self.duration_cache[period]={key=key,value=fitted} end
        self.stat_values[period]=fitted
        local contents=Vertical:new{align="left",label(({monthly="本月",weekly="本周",daily="今日"})[period],14,false),
            slot(label(fitted.text,fitted.size,true),bw-12*s,(fitted.secondary and 25 or 42)*s,"left")}
        if fitted.secondary then contents[#contents+1]=slot(label(fitted.secondary,12,false),bw-12*s,17*s,"left") end
        local cb=function() if actions.statistics then actions.statistics(period) end end
        local b=Button:new{text="",width=bw,height=60*s,padding=0,bordersize=0,callback=cb,enabled=not self.refreshing}
        b.label_widget:free();b.label_container[1]=slot(contents,bw,60*s,"left")
        self.stat_buttons[#self.stat_buttons+1]=b;stats[#stats+1]=b
    end
    self.stats_button=self.stat_buttons[1]
    local function tab(text,category)
        local b=textbutton(text,90*s,function() self:setCollection(category) end,21,"left")
        local body=Vertical:new{align="left",label(text,21,self.category==category),
            Span:new{width=5*s},self.category==category and line(42*s,2) or Span:new{width=2*s}}
        b.label_widget:free();b.label_container[1]=slot(body,90*s,44*s,"left");return b
    end
    self.collection_sync_button=Button:new{text="同步",width=math.floor(72*s),height=math.floor(32*s),
        padding=0,bordersize=math.max(1,math.floor(s)),radius=math.floor(6*s),
        text_font_size=15,text_font_bold=false,callback=actions.refresh,enabled=not self.refreshing}
    self.filters={tab("书架","shelf"),tab("本地","local"),self.collection_sync_button}
    local tabs=Horizontal:new{align="center",self.filters[1],self.filters[2],
        require("ui/widget/horizontalspan"):new{width=width-180*s-self.collection_sync_button:getSize().w},self.collection_sync_button}
    self.filter_button=textbutton("筛选 / 排序",120*s,function() if actions.filter then actions.filter() end end,15,"right",28*s)
    local filtered=self:filtered()
    local descriptions={full="全书下载",partial="部分下载",none="未下载"}
    local summary=#filtered.." 本 · "..require("welite/collection").sorts[self.sort]
    if descriptions[self.download_filter] then summary=summary.." · "..descriptions[self.download_filter] end
    if self.query~="" then summary=summary.." · 搜索中" end
    local summary_width=width-self.filter_button:getSize().w
    local summary_label=label(summary,12,false)
    summary_label.max_width=summary_width-8*s
    local header=Vertical:new{align="left",head,line(width,1),Span:new{width=4*s},
        stats,Span:new{width=4*s},line(width,1),Span:new{width=6*s},tabs,
        Horizontal:new{align="center",slot(summary_label,summary_width,28*s,"left"),self.filter_button},Span:new{width=12*s}}
    local footer_height=52*s
    local available=h-2*pad-header:getSize().h-footer_height
    local columns=w<screen:scaleBySize(540) and 2 or 3
    local rows=available<330*s and 1 or 2
    self.page_size=columns*rows
    local filtered=self:filtered()
    self.pages=math.max(1,math.ceil(#filtered/self.page_size))
    self.page=math.max(1,math.min(self.page,self.pages))
    self.visible={};self.cards={};self.layout={{self.brand,self.login_button,self.sync_button},self.stat_buttons,self.filters,{self.filter_button}}
    local grid=Vertical:new{align="left"}
    local row_height=math.floor(available/rows)
    local cell_width=math.floor(width/columns)
    for row=1,rows do
        local line=Horizontal:new{align="top"};local focus={}
        for col=1,columns do
            local index=(self.page-1)*self.page_size+(row-1)*columns+col
            local item=filtered[index]
            if item then
                self.visible[#self.visible+1]=item
                local cover_h=math.max(40,math.floor(row_height-80*s))
                local cover_w=math.min(math.floor(cover_h*2/3),math.floor(cell_width-24*s))
                local image
                local path=self.cover_paths[item.kind..":"..item.id]
                if path then
                    image=require("ui/widget/imagewidget"):new{file=path,width=cover_w,height=cover_h,
                        file_do_cache=false,scale_factor=0,alpha=true}
                else
                    image=Frame:new{padding=8*s,bordersize=1,background=require("ffi/blitbuffer").COLOR_WHITE,
                        Center:new{dimen=Geom:new{w=cover_w-16*s,h=cover_h-16*s},
                            Box:new{text=Shelf.coverErrorText((self.cover_errors or {})[item.kind..":"..item.id]) or item.title,width=cover_w-20*s,height=cover_h-20*s,
                                height_adjust=true,height_overflow_show_ellipsis=true,
                                alignment="center",face=Font:getFace("cfont",17)}}}
                end
                if item.kind=="book" then
                    local overlay=require("ui/widget/overlapgroup"):new{allow_mirroring=false,
                        Center:new{dimen=Geom:new{w=cover_w,h=cover_h},image}}
                    local function badge(text,align)
                        return Frame:new{overlap_align=align,padding=2*s,padding_top=0,padding_bottom=0,bordersize=1,
                            background=require("ffi/blitbuffer").COLOR_WHITE,
                            Text:new{text=text,face=Font:getFace("cfont",10),bold=true}}
                    end
                    local downloaded=(self.downloads or {})[item.kind..":"..item.id]
                    if downloaded then overlay[#overlay+1]=badge(downloaded=="full" and "已下载" or "部分下载","left") end
                    overlay[#overlay+1]=badge(Shelf.progressText(item),"right")
                    image=overlay
                end
                local title=Text:new{text=item.title,max_width=cell_width-16*s,
                    face=Font:getFace("cfont",16)}
                local author=Text:new{text=item.author~="" and item.author or (item.kind=="articles" and "文章收藏" or "作者未知"),
                    max_width=cell_width-16*s,face=Font:getFace("cfont",13)}
                local content=Vertical:new{align="center",Center:new{dimen=Geom:new{w=cell_width-12*s,h=cover_h},image},
                    Span:new{width=6*s},title,Span:new{width=4*s},author}
                local card=Button:new{text="",width=cell_width,height=row_height-8*s,padding=4*s,bordersize=0,
                    enabled=not self.refreshing,callback=function() actions.detail(item) end,
                    hold_callback=function() if actions.download then actions.download(item) end end}
                card.label_widget:free();card.label_container[1]=content
                line[#line+1]=card;focus[#focus+1]=card;self.cards[#self.cards+1]=card
            else
                line[#line+1]=Center:new{dimen=Geom:new{w=cell_width,h=row_height},
                    label(#filtered==0 and row==1 and col==1 and (self.category=="local" and not self.inventory and "正在检查本地下载…" or "暂无书籍") or "",16,false)}
            end
        end
        grid[#grid+1]=line
        if #focus>0 then self.layout[#self.layout+1]=focus end
    end
    if #filtered==0 then
        grid:free()
        local empty=self.category=="local" and "本地还没有书籍" or "没有符合条件的书籍"
        if self.category=="local" and not self.inventory then empty="正在检查本地下载…" end
        local action=button(self.category=="local" and "去书架下载" or "清除筛选",width/2,function()
            self.query="";self.download_filter="all";self:setCollection("shelf")
        end)
        grid=Center:new{dimen=Geom:new{w=width,h=available},Vertical:new{align="center",label(empty,18,false),Span:new{width=16*s},action}}
        self.layout[#self.layout+1]={action}
    end
    self.previous=button("‹ 上一页",width/3,function() self:turn(-1) end,self.page>1)
    self.next=button("下一页 ›",width/3,function() self:turn(1) end,self.page<self.pages)
    local footer=Horizontal:new{self.previous,
        Center:new{dimen=Geom:new{w=width/3,h=44*s},label(self.page.." / "..self.pages,16,false)},self.next}
    self.layout[#self.layout+1]={self.previous,self.next}
    self[1]=Frame:new{padding=pad,bordersize=0,background=require("ffi/blitbuffer").COLOR_WHITE,
        Center:new{dimen=Geom:new{w=width,h=h-2*pad},Vertical:new{header,grid,footer}}}
    self.dimen=Geom:new{x=0,y=0,w=w,h=h}
    self.selected={x=1,y=1}
    self:refocusWidget()
end
function Shelf:redraw()
    self:build();UI:setDirty(self,"ui")
end
function Shelf:turn(delta)
    local page=math.max(1,math.min(self.pages,self.page+delta))
    if page==self.page then return end
    self.page=page;self:redraw()
    if self.actions.page then self.actions.page(self:visibleItems()) end
end
function Shelf:setCollection(category,sort)
    self.filtered_items=nil
    if category=="local" and self.download_filter=="none" then self.download_filter="all" end
    self.category=category or self.category;self.sort=sort or self.sort;self.page=1
    if self.actions.selection then self.actions.selection(self) end
    self:redraw()
    if self.actions.page then self.actions.page(self:visibleItems()) end
end
function Shelf:applyFilter(query,sort,download_filter)
    self.query=query or "";self.sort=sort or "cloud";self.download_filter=download_filter or "all"
    self:setCollection()
end
function Shelf:stopClock()
    if self.clock_timer then UI:unschedule(self.clock_timer);self.clock_timer=nil end
end
function Shelf:updateStatus()
    if not self.clock_label then return end
    if self.day_stamp~=Reading.dayStart(os.time()) then self:redraw();return end
    local status=require("welite/display").status(Device,require("ui/network/manager"))
    local old=self.last_status or {}
    if status.time~=old.time or status.wifi~=old.wifi or status.battery~=old.battery then
        self.clock_label:setText(status.time);self.wifi_label:setText(status.wifi);self.battery_label:setText(status.battery)
        self.battery_group:resetLayout()
        self.battery_bar.percentage=(status.capacity or 0)/100
        self.last_status=status;UI:setDirty(self,"ui",self.status_region)
    end
end
function Shelf:startClock()
    self:stopClock()
    self.clock_timer=function()
        self.clock_timer=nil
        if UI:getTopmostVisibleWidget()==self then self:updateStatus() end
        self:startClock()
    end
    UI:scheduleIn(60-tonumber(os.date("%S")),self.clock_timer)
end
function Shelf:onSuspend()
    self:stopClock()
    if self.quick_menu then self.quick_menu:onClose() end
    if self.quick_controls then self.quick_controls:cancel() end
end
function Shelf:onResume() self:updateStatus();self:startClock() end
Shelf.onNetworkConnected=Shelf.updateStatus
Shelf.onNetworkDisconnected=Shelf.updateStatus
Shelf.onCharging=Shelf.updateStatus
Shelf.onNotCharging=Shelf.updateStatus
function Shelf:setQuery(query)
    self.filtered_items=nil
    self.query=query;self.page=1;self:redraw()
    if self.actions.page then self.actions.page(self:visibleItems()) end
end
function Shelf:onQuickMenu()
    if self.quick_menu then return true end
    self.quick_controls=self.quick_controls or require("welite/controls").new(self.host)
    self.quick_menu=require("welite/pulldown"):new{controls=self.quick_controls,host=self.host,shelf=self,login=self.actions.login,sync=self.actions.status or self.actions.refresh,
        close_callback=function() self.quick_menu=nil;self:updateStatus() end}
    UI:show(self.quick_menu);return true
end
function Shelf:onSwipe(_,gesture)
    self.pulldown_drag=nil
    if gesture.direction=="south" and gesture.pos and gesture.pos.y<=Device.screen:getHeight()*0.12 then return self:onQuickMenu() end
    if gesture.direction=="west" then self:turn(1);return true end
    if gesture.direction=="east" then self:turn(-1);return true end
end
function Shelf:onNextPage() self:turn(1);return true end
function Shelf:onPreviousPage() self:turn(-1);return true end
function Shelf:onClose()
    UI:close(self)
    if self.close_callback then self.close_callback() end
    return true
end
function Shelf:onShow() self:startClock();UI:setDirty(self,"ui");return true end
function Shelf:onCloseWidget() self:onSuspend();UI:setDirty(nil,"ui") end
return Shelf

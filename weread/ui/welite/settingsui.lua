-- On-demand native dialogs; only one owned window, closed with its host.
local P=require('weread.ui.welite.preferences')
local S={};S.__index=S
function S.new(options)
    options=options or {}
    return setmetatable({ui=options.ui or require('ui/uimanager'),settings=options.settings or G_reader_settings,
        changed=options.changed,plugin=options.plugin},S)
end
function S:close()
    self.menu=nil
    if self.dialog then local dialog=self.dialog;self.dialog=nil;if not dialog.closed then self.ui:close(dialog) end end
end
function S:exitToKOReader()
    self:close()
    require('weread.ui.welite.reader_controls').close(self.plugin)
    self.plugin:closeWeReadUI()
end
function S:showDialog(dialog)
    -- Match the book-detail backing without retaining/blurring a screenshot.
    -- Native dialogs only invalidate their own rectangle, so invalidate the
    -- viewport on opening/closing as well to remove the gray backing reliably.
    local screen=require('device').screen
    local paint,on_show,on_close=dialog.paintTo,dialog.onShow,dialog.onCloseWidget
    local ui=self.ui
    dialog.paintTo=function(widget,bb,x,y)
        bb:paintRect(0,0,screen:getWidth(),screen:getHeight(),require('ffi/blitbuffer').Color8(0xCC))
        paint(widget,bb,x,y)
    end
    dialog.onShow=function(widget)
        if on_show then on_show(widget) end
        ui:setDirty(nil,'ui',screen:getSize())
    end
    dialog.onCloseWidget=function(widget)
        if on_close then on_close(widget) end
        ui:setDirty(nil,'ui',screen:getSize())
    end
    self:close();self.dialog=dialog;self.ui:show(dialog)
end
function S:save(change)
    P.save(change,self.settings)
    if self.changed then self.changed() end
end
function S:show()
    if self.plugin and self.plugin.getMainMenuItems then return self:showUnified() end
    local value=P.read(self.settings)
    local buttons={
        {{text='时间显示 · '..P.label(value.offset),callback=function() self:timezone() end}},
        {{text='启动 KOReader 时打开 WeLite · '..(value.autostart and '开启' or '关闭'),callback=function()
            self:save{autostart=not value.autostart};self:show()
        end}},
    }
    if self.plugin then buttons[#buttons+1]={{text='章节预下载',keep_menu_open=true,callback=function() self:prefetch() end}} end
    buttons[#buttons+1]={{text='关闭',callback=function() self:close() end}}
    self:showDialog(require('ui/widget/buttondialog'):new{title='WeLite 设置',buttons=buttons})
end
-- Render upstream menu definitions in the same bounded ButtonDialog as local
-- preferences. The facade preserves their updateItems callback contract.
function S:renderMenu(menu)
    if self.menu~=menu then return end
    local buttons={}
    local pages=math.max(1,math.ceil(#menu.item_table/menu.max_per_page))
    menu.page=math.max(1,math.min(menu.page,pages))
    for i=(menu.page-1)*menu.max_per_page+1,math.min(menu.page*menu.max_per_page,#menu.item_table) do
        local item=menu.item_table[i]
        local label=item.text_func and item.text_func() or item.text or ''
        if item.checked_func then label=label..' · '..(item.checked_func() and '开启' or '关闭') end
        if item.sub_item_table_func or item.sub_item_table then label=label..' ›' end
        local enabled=item.enabled~=false
        if item.enabled_func then enabled=item.enabled_func() end
        buttons[#buttons+1]={{text=label,enabled=enabled,callback=function() menu:onMenuSelect(item) end}}
    end
    if pages>1 then
        buttons[#buttons+1]={
            {text='上一页',enabled=menu.page>1,callback=function() menu.page=menu.page-1;menu:updateItems() end},
            {text=menu.page..' / '..pages,enabled=false},
            {text='下一页',enabled=menu.page<pages,callback=function() menu.page=menu.page+1;menu:updateItems() end},
        }
    end
    if #menu.stack==0 and self.plugin.closeWeReadUI then
        buttons[#buttons+1]={{text='退出到 KOReader',callback=function() self:exitToKOReader() end}}
    end
    buttons[#buttons+1]={{text=#menu.stack>0 and '返回' or '关闭',callback=function()
        if self.menu~=menu then return end
        local previous=table.remove(menu.stack)
        if previous then
            menu.item_table,menu.title,menu.page=previous.items,previous.title,previous.page
            menu:updateItems()
        else self:close() end
    end}}
    local dialog=require('ui/widget/buttondialog'):new{title=menu.title,buttons=buttons}
    self:showDialog(dialog)
    self.menu=menu
    local on_close=dialog.onCloseWidget
    dialog.onCloseWidget=function(widget)
        if self.dialog==widget then self.dialog=nil;self.menu=nil end
        if on_close then on_close(widget) end
    end
end
-- Stable IDs belong to the original definitions; grouping never relies on
-- translated labels or copies their persistence/network behavior.
function S:buildItems()
    local groups,main={},{}
    for _,item in ipairs(self.plugin:getMainMenuItems()) do
        if item.welite_id then main[item.welite_id]=item end
        if item.welite_settings_group then
            for _,group in ipairs(item.sub_item_table_func()) do groups[group.welite_id]=group end
        end
    end
    local function append(target,items,flatten)
        for _,item in ipairs(items) do
            if flatten and item.welite_id==flatten then
                append(target,item.sub_item_table_func())
            else target[#target+1]=item end
        end
    end
    local function children(id) return groups[id].sub_item_table_func() end
    local function category(id,text,build)
        return {welite_id=id,text=text,sub_item_table_func=build}
    end
    return {
        category('basic','基础设置',function() return {
            {text_func=function() return '时间显示 · '..P.label(P.read(self.settings).offset) end,
                keep_menu_open=true,callback=function() self:timezone() end},
            {text='启动 KOReader 时打开 WeLite',keep_menu_open=true,
                checked_func=function() return P.read(self.settings).autostart end,
                callback=function(menu)
                    self:save{autostart=not P.read(self.settings).autostart};menu:updateItems()
                end},
        } end),
        category('sync','同步与阅读时间',function()
            local items=children('sync')
            -- Keep authentication at the report action boundary so offline users
            -- can still change progress preferences without a login popup.
            for _,item in ipairs(self.plugin:getReadReportMenuItems()) do
                local copy={}
                for key,value in pairs(item) do copy[key]=value end
                for _,key in ipairs({'callback','sub_item_table_func'}) do
                    local action=item[key]
                    if action then copy[key]=function(...)
                        if self.plugin:requireLogin(true,true) then return action(...) end
                    end end
                end
                items[#items+1]=copy
            end
            return items
        end),
        category('download','下载与存储',function()
            local items={};append(items,children('download'),'prefetch');append(items,children('storage'))
            return items
        end),
        category('reading','阅读与批注',function()
            local items={}
            if main.annotation_visibility then items[#items+1]=main.annotation_visibility end
            append(items,children('reading'),'thought_popup')
            return items
        end),
        category('account','账号管理',function()
            local items={main.login}
            -- Login already displays the current account and opens its status.
            for _,item in ipairs(children('account')) do
                if item.welite_id~='account_status' then items[#items+1]=item end
            end
            return items
        end),
        category('about','关于与高级',function()
            local items=children('about');append(items,children('advanced'));return items
        end),
    }
end
function S:showUnified(section)
    local items=self:buildItems()
    local owner=self
    local screen=require('device').screen
    local menu={item_table=items,title='WeLite 设置',page=1,stack={},
        max_per_page=math.max(2,math.min(6,math.floor(screen:getHeight()/screen:scaleBySize(65))-4))}
    function menu:updateItems() owner:renderMenu(self) end
    function menu:closeMenu() if owner.menu==self then owner:close() end end
    function menu:onMenuSelect(item)
        if owner.menu~=self or item.enabled==false or (item.enabled_func and not item.enabled_func()) then return end
        if item.sub_item_table_func or item.sub_item_table then
            local children=item.sub_item_table_func and item.sub_item_table_func() or item.sub_item_table
            if not children then return end
            self.stack[#self.stack+1]={items=self.item_table,title=self.title,page=self.page}
            self.item_table,self.title,self.page=children,item.text_func and item.text_func() or item.text,1
            self:updateItems()
        elseif item.callback then
            if not (item.keep_menu_open or item.checked_func) then self:closeMenu() end
            local previous_dialog=owner.dialog
            item.callback(self)
            if item.checked_func and not item.check_callback_updates_menu and owner.dialog==previous_dialog then
                self:updateItems()
            end
        end
    end
    self.menu=menu
    self:renderMenu(menu)
    if section then
        for _,item in ipairs(items) do if item.welite_id==section then menu:onMenuSelect(item);break end end
    end
    return menu
end
function S:returnToBasic()
    if self.plugin and self.plugin.getMainMenuItems then self:showUnified('basic') else self:show() end
end
function S:prefetch()
    self:showDialog(require('weread.ui.welite.prefetch_settings').new(self.plugin,function() self:show() end))
end
function S:timezone()
    self:showDialog(require('ui/widget/buttondialog'):new{title='时间显示\n仅影响 WeLite 显示，不修改设备时钟。\n云端阅读统计仍按 UTC+8 自然日计算。',buttons={
        {{text='跟随系统',callback=function() self:save{timezone=true};self:returnToBasic() end}},
        {{text='手动设置时区',callback=function() self:manual() end}},
        {{text='返回',callback=function() self:returnToBasic() end}},
    }})
end
function S:manual()
    local offset=P.read(self.settings).offset or 480
    local dialog
    dialog=require('ui/widget/inputdialog'):new{title='固定 UTC 时区（不自动切换夏令时）\n格式 +08:00，范围 -12:00 至 +14:00\n分钟支持 00 / 15 / 30 / 45',
        input=P.label(offset):sub(4),buttons={{
            {text='取消',id='close',callback=function() self:timezone() end},
            {text='保存',callback=function()
                local n=P.parse(dialog:getInputText())
                if n==nil then
                    self.ui:show(require('ui/widget/infomessage'):new{text='时区格式无效，例如 +08:00 或 -03:30。',timeout=3});return
                end
                self:save{timezone=true,offset=n};self:returnToBasic()
            end},
        }}}
    self:showDialog(dialog);dialog:onShowKeyboard()
end
function S:askStartup(open)
    self:showDialog(require('ui/widget/buttondialog'):new{title='欢迎使用 WeLite\n是否在每次启动 KOReader 时自动打开 WeLite？\n以后可在「WeLite 设置」中修改。',buttons={
        {{text='是，启动时打开 WeLite',callback=function()
            self:save{autostart=true};self:close();open()
        end}},
        {{text='暂不自动打开',callback=function() self:save{autostart=false};self:close() end}},
    }})
end
return S

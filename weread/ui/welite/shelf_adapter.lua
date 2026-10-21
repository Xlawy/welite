-- Translate community records/callbacks; all home pixels come from WeLite's shelf.lua.
local Shelf=require('weread.ui.welite.shelf')
local UI=require('ui/uimanager')
local Screen=require('device').screen
local M={}
M.sorts={default='cloud',time_desc='recent',added_desc='added',name_asc='title'}
M.downloads={not_downloaded='none',full='full',partial='partial'}
local Adapter=Shelf:extend{}

function Adapter:filtered() return self.items end
function Adapter:turn(delta)
    local page=math.max(1,math.min(self.pages,self.page+delta))
    if page~=self.page and self.on_page_changed then self.on_page_changed(page) end
end
function Adapter:setCollection(category)
    if category=='local' then
        if self.on_local then self.on_local() end
    elseif self.on_cloud then self.on_cloud() end
end
function Adapter:getScrollOffset() return nil end
function Adapter:setRefreshing(value)
    self.refreshing=value
    self.sync_status=value and '同步中…' or self.persisted_status
    if not self.welite_closed then self:redraw() end
end
function Adapter:setSyncStatus(value)
    self.persisted_status=value;self.sync_status=value
    if not self.welite_closed then self:redraw() end
end
function Adapter:showSourceMenu()
    return require('weread.ui.library_view').showSourceMenu(self)
end
function Adapter:showOptions()
    return require('weread.ui.library_view').showOptions(self)
end
function Adapter:onQuickMenu()
    self.quick_controls=self.quick_controls or require('weread.ui.welite.controls').new(self.host)
    self.quick_controls.plugin_settings=function() require("weread.ui.welite.home").settings(self):show() end
    return Shelf.onQuickMenu(self)
end
function Adapter:onSuspend()
    if self.welite_settings_ui then self.welite_settings_ui:close() end
    Shelf.onSuspend(self)
end
function Adapter:onCloseWidget()
    self.welite_closed=true
    if self.welite_settings_ui then self.welite_settings_ui:close() end
    Shelf.onCloseWidget(self)
end

function M.show(data,callbacks)
    callbacks=callbacks or {}
    local source=data.mode=='public_account' and data.accounts or data.books
    local items,paths,downloads={},{},{}
    for _,book in ipairs(source or {}) do
        local id=tostring(book.bookId or book.book_id or '')
        local kind=data.mode=='public_account' and 'articles' or 'book'
        local item={kind=kind,id=id,title=book.title or id,author=book.author or '',
            percent=book.progress,record=book}
        items[#items+1]=item
        paths[kind..':'..id]=(data.cover_paths or {})[book]
        downloads[kind..':'..id]=book._download_state or (book._cached and 'partial' or nil)
    end
    local view
    local actions={
        more=function() require('weread.ui.welite.home').menu(view) end,
        login=callbacks.on_login or callbacks.on_main_menu,
        refresh=callbacks.on_refresh,status=callbacks.on_refresh,
        filter=callbacks.on_filter_draft,
        statistics=function(mode) if callbacks.on_statistics then callbacks.on_statistics(mode=='daily' and 'monthly' or mode) end end,
        detail=function(item) if callbacks.on_select then callbacks.on_select(item.record,data.mode) end end,
        download=function(item) if callbacks.on_hold then callbacks.on_hold(item.record,data.mode)
            elseif callbacks.on_select then callbacks.on_select(item.record,data.mode) end end,
    }
    local props={items=items,actions=actions,inventory=true,host=data.welite_host,
        overview=data.welite_overview,logged_in=data.logged_in==true,
        sync_status=data.sync_status or '未同步',persisted_status=data.sync_status or '未同步',
        category=data.local_only and 'local' or 'shelf',query=data.keyword or '',
        sort=M.sorts[data.sort_key] or 'cloud',download_filter=M.downloads[data.download_filter] or 'all',
        cover_paths=paths,downloads=downloads,page=data.page or 1,
        -- Keep the controller's callback contract and optional community menu context.
        mode=data.mode,keyword=data.keyword,books=data.books,accounts=data.accounts,
        groups=data.groups,group_key=data.group_key,group_label=data.group_label,wp_enable=data.wp_enable~=false,
        local_only=data.local_only,cover_mode=true,paged=true,sort_label=data.sort_label,filter_label=data.filter_label,
        total_books=data.total_books,
    }
    for name,callback in pairs(callbacks) do props[name]=callback end
    view=Adapter:new(props)
    view.page_count=view.pages
    UI:show(view)
    return view
end

-- Measure the identical empty widget once per screen/font scale; no covers or networking.
local measured_key,measured
function M.getLayout()
    local w,h=Screen:getWidth(),Screen:getHeight()
    local key=w..':'..h..':'..Screen:scaleBySize(600)
    if key~=measured_key then
        local probe=Shelf:new{items={},actions={},inventory=true}
        local columns=w<Screen:scaleBySize(540) and 2 or 3
        measured={page_size=probe.page_size,columns=columns,rows=probe.page_size/columns}
        probe:free();measured_key=key
    end
    return measured
end
return M

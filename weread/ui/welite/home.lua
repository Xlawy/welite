-- Navigation only. The home is rendered by the original WeLite shelf widget.
local M={}
local UI=require('ui/uimanager')
local Device=require('device')
function M.mainMenu(plugin)
    local items=plugin:getMainMenuItems()
    items.icon='appbar.menu'
    local menu=require('ui/widget/touchmenu'):new{width=Device.screen:getWidth(),tab_item_table={items}}
    UI:show(menu)
    return menu
end

function M.settings(owner)
    if not owner.welite_settings_ui then
        owner.welite_settings_ui=require('weread.ui.welite.settingsui').new{plugin=owner.welite_plugin or (owner.downloader and owner),changed=function()
            if owner.updateStatus and not owner.welite_closed then owner:updateStatus() end
        end}
    end
    return owner.welite_settings_ui
end

function M.queueStartup(plugin)
    -- Startup navigation belongs to FileManager, never interrupt an open book.
    if plugin.ui and plugin.ui.document then return false end
    return require('weread.ui.welite.startup').instance:queue(UI,
        function() return require('weread.ui.welite.preferences').read() end,
        function(open) M.settings(plugin):askStartup(open) end,
        function() plugin:showBookshelf() end)
end

function M.menu(view)
    local Dialog=require('ui/widget/buttondialog')
    local dialog
    local function action(fn) return function() UI:close(dialog);if fn then fn() end end end
    dialog=Dialog:new{title='书架管理',title_align='center',buttons={
        {{text='下载书籍…',callback=action(function()
            local rows={}
            for _,item in ipairs(view.items or {}) do
                rows[#rows+1]={text=item.title,callback=function() view.actions.download(item) end}
            end
            UI:show(require('ui/widget/menu'):new{title='选择下载书籍',item_table=rows,
                width=Device.screen:getWidth(),height=Device.screen:getHeight()})
        end)}},
        {{text='公众号',enabled=view.welite_plugin~=nil,callback=action(function()
            if view.welite_plugin then view.welite_plugin:showMPShelfPage() end
        end)}},
        {{text='重新加载本页封面',callback=action(view.on_retry_covers)}},
        {{text='切换账号',callback=action(view.on_switch_account)}},
        {{text='退出登录',callback=action(view.on_logout)}},
        {{text='社区功能…',callback=action(function() M.communityMenu(view) end)}},
    }}
    UI:show(dialog)
    return dialog
end

function M.communityMenu(view)
    local dialog
    local function action(fn) return function() UI:close(dialog);fn() end end
    dialog=require('ui/widget/buttondialog'):new{title='社区功能',buttons={
        {{text='微信读书 · 全部功能',callback=action(view.on_main_menu)}},
        {{text='公众号与微信分组',callback=action(function() view:showSourceMenu() end)}},
        {{text='书架显示与阅读状态筛选',callback=action(function() view:showOptions() end)}},
        {{text='刷新阅读统计',callback=action(view.on_refresh_statistics)}},
    }}
    UI:show(dialog)
end
return M

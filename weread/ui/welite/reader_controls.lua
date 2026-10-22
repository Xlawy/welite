-- Add the WeLite device panel without replacing community reading/annotation actions.
local M={}
function M.close(plugin)
    plugin.welite_pulldown_drag=nil
    if plugin.welite_annotations_panel then plugin.welite_annotations_panel:onClose() end
    if plugin.welite_reader_panel then plugin.welite_reader_panel:onClose() end
    if plugin.welite_settings_ui then plugin.welite_settings_ui:close() end
end
function M.install(plugin)
    require("weread.ui.welite.reading_sync").onReaderReady(plugin)
    local ui=plugin.ui
    if not ui or not ui.registerTouchZones then return end
    ui:registerTouchZones{{id='welite_community_pulldown',ges='swipe',screen_zone={ratio_x=0,ratio_y=0,ratio_w=1,ratio_h=0.12},
        -- Native reader/menu zones consume swipe events even when registered
        -- earlier. Declare priority just like the top tap and drag zones.
        overrides={'readermenu_swipe','readermenu_ext_swipe','rolling_swipe','paging_swipe'},
        handler=function(gesture)
            if gesture.direction=='south' then return M.show(plugin) end
            return false
        end},
        {id='welite_community_tap',ges='tap',screen_zone={ratio_x=0,ratio_y=0,ratio_w=1,ratio_h=0.12},
            overrides={'readermenu_tap','readermenu_ext_tap','tap_forward','tap_backward'},
            handler=function() return M.show(plugin) end},
        {id='welite_community_pan',ges='pan',screen_zone={ratio_x=0,ratio_y=0,ratio_w=1,ratio_h=1},
            overrides={'readermenu_pan','readermenu_ext_pan','rolling_pan','paging_pan'},
            handler=function(gesture)
                plugin.welite_pulldown_drag=gesture.start_pos and gesture.start_pos.y<=require('device').screen:getHeight()*.12
                    and gesture.direction=='south'
                return plugin.welite_pulldown_drag or false
            end},
        {id='welite_community_release',ges='pan_release',screen_zone={ratio_x=0,ratio_y=0,ratio_w=1,ratio_h=1},
            overrides={'rolling_pan_release','paging_pan_release'},handler=function()
                if plugin.welite_pulldown_drag then plugin.welite_pulldown_drag=nil;return M.show(plugin) end
                return false
            end},
    }
end
function M.syncStatus(plugin)
    local status=plugin.progress_sync and plugin.progress_sync:status() or {}
    if status.pulling or status.uploading then return '同步中…' end
    if status.state=='error' then return '同步失败' end
    if status.state=='offline' then return '等待联网' end
    if status.state=='awaiting_choice' then return '待选进度' end
    if status.dirty then return '待上传' end
    if status.verified then return '已同步' end
    return '同步进度'
end
function M.show(plugin)
    if plugin.welite_reader_panel then return true end
    local ui=plugin.ui
    if not ui or not ui.document then return false end
    local controls=require('weread.ui.welite.controls').new(ui)
    controls.plugin_settings=function() require("weread.ui.welite.home").settings(plugin):show() end
    local chapters={}
    if ui.toc then
        chapters.catalog=function() ui.toc:onShowToc() end
        local page=ui.rolling and ui.rolling.current_page
        if page and ui.toc:getPreviousChapter(page) then chapters.previous=function() ui.rolling:onGotoPrevChapter() end end
        if page and ui.toc:getNextChapter(page) then chapters.next=function() ui.rolling:onGotoNextChapter() end end
    end
    plugin.welite_reader_panel=require('weread.ui.welite.pulldown'):new{
        controls=controls,host=ui,chapters=chapters,sync_status=M.syncStatus(plugin),
        auth_view={logged_in=plugin.settings and (plugin.settings:get('account',{}).login_method or '')~=''},
        sync=function() plugin:onWeReadSyncProgress() end,
        annotations=plugin._xpointerOverlayPrototypeAvailable and plugin:_xpointerOverlayPrototypeAvailable()
            and function() return require('weread.ui.welite.annotations').show(plugin) end or nil,
        home=function()
            local file=ui.document.file
            ui:onClose()
            if ui.showFileManager then ui:showFileManager(file) end
            local manager=require('apps/filemanager/filemanager').instance
            if manager and manager.weread then manager.weread:showBookshelf()
            else plugin:showInfo("阅读已关闭；请从工具菜单打开 WeLite 书架。") end
        end,
        login=function() plugin:onShowWeReadQuickMenu() end,
        close_callback=function() controls:cancel();plugin.welite_reader_panel=nil end}
    require('ui/uimanager'):show(plugin.welite_reader_panel)
    return true
end
return M

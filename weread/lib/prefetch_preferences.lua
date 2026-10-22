-- Shared preference actions for the upstream menu and WeLite settings.
local M={}
local function queue_current(plugin)
    local id=plugin._current_weread_book_id
    if not id or plugin.settings:get('cache',{}).auto_prefetch_next_chapter~=true then return end
    local account=plugin.settings:get('account',{}).user_vid
    local token={};plugin._prefetch_setting_check=token
    require('ui/uimanager'):scheduleIn(0.1,function()
        if plugin._prefetch_setting_check~=token then return end
        plugin._prefetch_setting_check=nil
        if plugin._current_weread_book_id==id
            and plugin.settings:get('account',{}).user_vid==account
            and plugin.settings:get('cache',{}).auto_prefetch_next_chapter==true then
            plugin:maybePrefetchNextChapter(id)
        end
    end)
end
function M.set_chapters(plugin,enabled)
    local cache=plugin.settings:get('cache',{})
    cache.auto_prefetch_next_chapter=enabled==true
    plugin.settings:set('cache',cache);plugin.settings:flush()
    if not enabled then
        plugin._prefetch_setting_check=nil
        plugin:cancelAnnotationPrefetch()
        plugin.downloader:cancelPrefetch('setting_disabled')
    else queue_current(plugin) end
end
function M.set_annotations(plugin,enabled)
    local result=plugin:setAnnotationPrefetchEnabled(enabled==true)
    if enabled then queue_current(plugin) end
    return result
end
function M.set_notifications(plugin,enabled)
    local cache=plugin.settings:get('cache',{})
    cache.show_prefetch_notifications=enabled==true
    plugin.settings:set('cache',cache);plugin.settings:flush()
end
return M

local List=require('welite.ui.welite.record_list')
local _=require('welite.lib.i18n').tr
local M={}
function M.show(data,callbacks)
    return List.show({heading=_('Search WeRead'),caption=data.query,items=data.items,status=data.status,
        empty_text=_('No search results.'),action_text=_('Search again')},
        {on_select=callbacks.on_select,on_retry=callbacks.on_retry,on_action=callbacks.on_search,on_close=callbacks.on_close})
end
return M

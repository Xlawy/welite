package.path='./?.lua;'..package.path
local current,dialog,message
package.preload['ui/uimanager']=function() return {
 show=function(_,v) dialog=v end,close=function(_,v) if v.callbacks then v.callbacks.on_close() end end} end
package.preload['ui/widget/confirmbox']=function() return {new=function(_,v) return v end} end
package.preload['welite.ui.welite.record_list']=function() return {show=function(data,callbacks)
 current={data=data,callbacks=callbacks};return current end} end
package.preload['ffi/util']=function() return {template=function(s,...)
 local args={...};return (s:gsub('%%(%d+)',function(n) return tostring(args[tonumber(n)]) end)) end} end
local Review=require('welite.ui.reading_time_review')
local Ledger=require('welite.lib.reading_time_ledger')
local values,clock={},0
local storage={get=function(_,k,d) return values[k] or d end,set=function(_,k,v) values[k]=v end,flush=function() end}
local ledger=Ledger.new(storage,function() return clock end)
local account='one'
local plugin={read_report={time_ledger=ledger},settings={get=function(_,k,d)
 if k=='account' then return {user_vid=account} elseif k=='books' then return {book={title='Synthetic book'}} end;return d end},
 showInfo=function(_,text) message=text end}
local function unknown()
 ledger:start('one','book');clock=clock+12;ledger:stop()
 local batch=assert(ledger:begin_pending('one','book'));ledger:settle(batch,'unknown')
end
unknown();Review.show(plugin)
assert(#current.data.items==1 and current.data.items[1].title=='Synthetic book')
current.callbacks.on_select(current.data.items[1]);assert(ledger:status('one','book').uncertain==12)
-- Cancel has no mutation callback; closing the parent invalidates old actions.
current.callbacks.on_close();dialog.ok_callback();assert(ledger:status('one','book').uncertain==12)
Review.show(plugin);current.callbacks.on_select(current.data.items[1])
account='two';dialog.ok_callback();assert(ledger:status('one','book').uncertain==12)
account='one';Review.show(plugin);current.callbacks.on_select(current.data.items[1])
dialog.other_buttons[1][1].callback();assert(ledger:status('one','book').pending==0)
dialog.ok_callback();assert(ledger:status('one','book').pending==12 and #current.data.items==0)
dialog.ok_callback();assert(ledger:status('one','book').pending==12,'duplicate confirmation')
local retry=ledger:begin_pending('one','book');ledger:settle(retry,'unknown')
Review.show(plugin);current.callbacks.on_select(current.data.items[1]);dialog.ok_callback()
assert(ledger:status('one','book').uncertain==0 and ledger:status('one','book').acknowledged==0)
unknown();Review.show(plugin);current.callbacks.on_select(current.data.items[1]);local stale=dialog
unknown();stale.ok_callback();assert(message and ledger:status('one','book').uncertain==24)
print('reading_time_review_spec: list, cancel, two-step retry, explicit review, stale dialog and account isolation passed')

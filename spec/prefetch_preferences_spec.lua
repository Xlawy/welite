package.path='./?.lua;'..package.path
local pending={}
package.preload['ui/uimanager']=function() return {scheduleIn=function(_,_,fn) pending[#pending+1]=fn end} end
local P=require('welite.lib.prefetch_preferences')
local values={cache={},account={user_vid='one'}}
local started,cancelled,annotations,flushed=0,0,0,0
local plugin={_current_weread_book_id='book',settings={get=function(_,k,d) return values[k] or d end,
    set=function(_,k,v) values[k]=v end,flush=function() flushed=flushed+1 end},
    downloader={cancelPrefetch=function(_,reason) assert(reason=='setting_disabled');cancelled=cancelled+1 end},
    cancelAnnotationPrefetch=function() annotations=annotations+1 end,
    maybePrefetchNextChapter=function(_,id) assert(id=='book');started=started+1 end,
    setAnnotationPrefetchEnabled=function(_,on) values.cache.prefetch_annotations=on;return true end}
local function drain() local tasks=pending;pending={};for _,task in ipairs(tasks) do task() end end
P.set_chapters(plugin,true);P.set_annotations(plugin,true)
assert(started==0);drain();assert(started==1,'rapid related toggles must schedule only one current-book check')
P.set_chapters(plugin,true);P.set_chapters(plugin,false);drain()
assert(started==1 and cancelled==1 and annotations==1,'turning off cancels both jobs and invalidates a queued start')
assert(values.cache.prefetch_annotations==true,'retain the subordinate preference')
P.set_chapters(plugin,true);values.account.user_vid='two';drain();assert(started==1)
P.set_chapters(plugin,true);plugin._current_weread_book_id=nil;drain();assert(started==1)
P.set_notifications(plugin,false);assert(values.cache.show_prefetch_notifications==false and flushed>0)
print('prefetch_preferences_spec: shared settings, cancellation, deferred enable and account guards passed')

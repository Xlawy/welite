package.path='./?.lua;'..package.path
local Scope=require('weread.lib.progress_scope')
-- A retained cache must not become a progress request for the next account.
local foreign={readUpdateTime=999999,cached_file='old-account.epub',
    home_remote_position={account='old',position={percent=42}}}
local scoped,scoped_ids=Scope.select({{bookId='current',readUpdateTime=1}},
    {foreign=foreign,unknown={cached_file='legacy.epub',readUpdateTime=999999}},'new')
assert(#scoped==1 and scoped_ids.current and not scoped_ids.foreign and not scoped_ids.unknown,
    'foreign and unowned local caches leaked into current-account requests')
assert(foreign.cached_file=='old-account.epub' and foreign.home_remote_position.account=='old',
    'filtering must not remove or reassign the old cache')
local shelf={}
for i=1,1000 do shelf[i]={bookId=tostring(i),readUpdateTime=i} end
shelf[#shelf+1]={bookId='never-read'}
shelf[#shelf+1]={bookId='MP_WXS_1',readUpdateTime=999999}
local saved={['1']={cached_full_book='full.epub'},['2']={cached_chapters={['3']='chapter.epub'}},
    ['local-only']={cached_file='local.epub',home_remote_position={account='one'}},['metadata-only']={title='not downloaded'},
    ['empty-path']={cached_file='',cached_chapters={['1']=''}},
    ['MP_WXS_1']={cached_file='article.epub'}}
local targets,ids=Scope.select(shelf,saved,'one')
assert(#targets==13 and ids['1'] and ids['2'] and ids['local-only'])
assert(ids['991'] and ids['1000'] and not ids['990'])
assert(not ids['never-read'] and not ids['metadata-only'] and not ids['empty-path'] and not ids['MP_WXS_1'])
assert(#shelf==1002 and saved['local-only'].bookId==nil,'selection does not rewrite source records')
-- Local reading, numeric IDs, duplicate cloud entries and millisecond timestamps.
local entries,selected=Scope.select({{bookId=1,readUpdateTime=1700000000000},{bookId='1'}},
    {[1]={cached_file='one.epub'},two={last_local_position={account_id='one',captured_at=1700000001}}},'one')
assert(#entries==2 and selected['1'] and selected.two)
local empty=Scope.select({{bookId='unread'},{bookId='bad',readUpdateTime='oops'}},{})
assert(#empty==0)
local all=Scope.select({}, {a={cached_file='a',last_local_position={account_id='one'}},
    b={cached_full_book='b',last_reported_position={account='one'}}},'one')
assert(#all==2,'local downloads remain eligible even after removal from cloud bookshelf')
for _,field in ipairs({'last_local_position','pending_upload_position','last_uploaded_position',
    'last_remote_position','last_reported_position','home_remote_position'}) do
    local wrapped=field=='last_reported_position' or field=='home_remote_position'
    local record={cached_file='owned.epub',[field]={[wrapped and 'account' or 'account_id']=123}}
    assert(#Scope.select({}, {owned=record},'123')==1,'numeric and string account IDs must agree: '..field)
    assert(#Scope.select({}, {owned=record},'other')==0,'foreign owner accepted: '..field)
    assert(#Scope.select({}, {owned=record})==0,'missing account must not authorize local-only sync')
end
local current_shelf={{bookId='shared',readUpdateTime=1},{bookId='unread'}}
local retained={shared=foreign,unread={cached_file='foreign.epub',last_local_position={account_id='old',captured_at=999999}}}
local shared,shared_ids=Scope.select(current_shelf,retained,'new')
assert(#shared==1 and shared_ids.shared and not shared_ids.unread,
    'current cloud activity remains eligible without borrowing foreign downloads or recency')
local own_local={cached_file='own.epub',last_local_position={account_id='new',captured_at=10},
    home_remote_position={account='old'}}
assert(#Scope.select({}, {owned=own_local},'new')==1,'current local reading supersedes an older cloud observation')
assert(#Scope.select({}, {owned=own_local},'old')==0,'old cloud observation must not override current local ownership')
assert(#Scope.select({}, {foreign=foreign},'old')==1,'switching back must recover the retained local book')
assert(#Scope.select({}, {unknown={cached_file='legacy.epub',home_remote_position={account=''}}},'')==0)
print('progress_scope_spec: 1002 shelf entries -> 13 unique targets; recent cap, downloads, local timestamps and exclusions passed')

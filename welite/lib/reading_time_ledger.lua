-- Durable online reading time; uncertain writes are never blindly replayed.
-- No credentials, text, per-page writes, or network calls live here.
local M={}
M.__index=M
M.MAX_ENTRIES=256
local KEY='welite_reading_time'
local owners=setmetatable({},{__mode='v'})
local reservations=setmetatable({},{__mode='v'})
-- One bounded state per storage with failed writes. All parent-side handles
-- must see it until a successful flush, or a stale handle can erase new data.
local dirty_states={}
local function storage_key(ledger) return ledger.storage_id or ledger.settings end
local function reservation_key(ledger,account,book)
    local scope=tostring(ledger.storage_id or ledger.settings)
    account=tostring(account);book=tostring(book)
    return scope..':'..#account..':'..account..':'..book
end
local function add_uncertain(entry,seconds)
    entry.uncertain=entry.uncertain+seconds
end
local function copy(value)
    if type(value)~='table' then return value end
    local result={};for key,item in pairs(value) do result[key]=copy(item) end;return result
end
-- Reuse KOReader's SQLite binding; keep time checkpoints out of the potentially
-- large preferences/books file. One small transactional row, parent writes only.
function M.open(settings,clock)
    -- The old ledger includes offline reading. Leave it untouched and never
    -- import it into the online-only accounting stream.
    local path=settings.data_dir..'/online-reading-time.sqlite3'
    local function database()
        local db=require('lua-ljsqlite3/init').open(path)
        db:exec('CREATE TABLE IF NOT EXISTS ledger (id INTEGER PRIMARY KEY, value TEXT NOT NULL)')
        return db
    end
    local staged
    local storage={get=function(_,_,default)
        local db=database();local stmt
        local ok,value=pcall(function()
            stmt=db:prepare('SELECT value FROM ledger WHERE id=1')
            local row=stmt:step()
            return row and require('json').decode(row[1]) or default
        end)
        if stmt then stmt:close() end;db:close()
        if not ok then error(value) end
        return value
    end,set=function(_,_,value) staged=value end,flush=function()
        local db=database();local stmt
        local ok,err=pcall(function()
            stmt=db:prepare('INSERT OR REPLACE INTO ledger(id,value) VALUES(1,?)')
            stmt:bind(require('json').encode(staged)):step()
        end)
        if stmt then stmt:close() end;db:close()
        if not ok then error(err) end
        staged=nil
    end}
    local ledger=M.new(storage,clock)
    ledger.storage_id=path
    return ledger
end
function M.new(settings,clock)
    return setmetatable({settings=settings,clock=assert(clock)},M)
end
function M:_state()
    return copy(dirty_states[storage_key(self)] or self.settings:get(KEY,{accounts={},sequence=0}))
end
function M:_save(state)
    dirty_states[storage_key(self)]=copy(state)
    self.settings:set(KEY,state)
    self.settings:flush()
    dirty_states[storage_key(self)]=nil
end
function M:_entry(state,account,book,create)
    if account==nil or tostring(account)=='' then return nil,'account_unavailable' end
    account,book=tostring(account),tostring(book or '')
    if book=='' then return nil,'book_unavailable' end
    state.accounts=state.accounts or {}
    local books=state.accounts[account]
    if books and books[book] then return books[book] end
    if not create then return nil end
    local count,retired_account,retired_book=0
    local owner=self.storage_id and owners[self.storage_id] or self
    local active=owner and owner.active
    for account_id,items in pairs(state.accounts) do
        for book_id,item in pairs(items) do
            count=count+1
            -- These are completed bookkeeping entries, not unsent time.
            -- Keep even sub-second balances and every live request intact.
            if item.pending==0 and item.uncertain==0 and not item.inflight
                and not reservations[reservation_key(self,account_id,book_id)]
                and not (active and tostring(active.account)==account_id and active.book==book_id)
                and (not retired_account or account_id<retired_account
                    or (account_id==retired_account and book_id<retired_book)) then
                retired_account,retired_book=account_id,book_id
            end
        end
    end
    if count>=M.MAX_ENTRIES then
        if count~=M.MAX_ENTRIES or not retired_account then return nil,'time_ledger_full' end
        local retired=state.accounts[retired_account]
        retired[retired_book]=nil
        if not next(retired) then state.accounts[retired_account]=nil end
    end
    books=books or {};state.accounts[account]=books
    books[book]={pending=0,uncertain=0,acknowledged=0}
    return books[book]
end
function M:start(account,book)
    local owner=self.storage_id and owners[self.storage_id]
    if owner and owner~=self and owner.active then return false,'reading_time_active_elsewhere' end
    self:stop()
    local state=self:_state()
    local entry,err=self:_entry(state,account,book,true)
    if not entry then return false,err end
    -- A process that died before settling a persisted attempt cannot tell
    -- whether the server accepted it. Keep it separate from retryable time.
    if entry.inflight and not reservations[reservation_key(self,account,book)] then
        add_uncertain(entry,entry.inflight.seconds)
        entry.inflight=nil
    end
    self:_save(state)
    self.active={account=account,book=tostring(book),at=self.clock()}
    if self.storage_id then owners[self.storage_id]=self end
    return true
end
function M:checkpoint()
    local active=self.active
    if not active then return 0 end
    local now=self.clock()
    local elapsed=now-active.at
    if elapsed<=0 then return 0 end
    local state=self:_state()
    local entry,err=self:_entry(state,active.account,active.book,true)
    if not entry then return nil,err end
    entry.pending=entry.pending+elapsed
    active.at=now
    self:_save(state)
    return elapsed
end
function M:stop()
    if not self.active then return end
    local ok,err=pcall(self.checkpoint,self)
    self.active=nil
    if self.storage_id and owners[self.storage_id]==self then owners[self.storage_id]=nil end
    if not ok then error(err) end
end
-- When no disconnect event was delivered, the interval since the last link
-- check may contain offline time. Drop that unobserved interval, not balances
-- already checkpointed while online. This pause does not write to disk.
function M:pause()
    self.active=nil
    if self.storage_id and owners[self.storage_id]==self then owners[self.storage_id]=nil end
end
function M:begin(max_seconds)
    self:checkpoint()
    local active=self.active
    if not active then return nil,'time_not_running' end
    return self:_reserve(active.account,active.book,max_seconds)
end
function M:_reserve(account,book,max_seconds)
    if reservations[reservation_key(self,account,book)] then return nil,'time_report_busy' end
    local state=self:_state()
    local entry,err=self:_entry(state,account,book,false)
    if not entry then return nil,err end
    if entry.inflight then return nil,'time_report_busy' end
    local seconds=math.floor(math.min(entry.pending,math.max(1,math.floor(max_seconds or 300)))+0.000001)
    if seconds<=0 then return nil,'no_elapsed_time' end
    state.sequence=(state.sequence or 0)+1
    local batch={id=state.sequence,seconds=seconds,account=account,book=tostring(book)}
    entry.pending=math.max(0,entry.pending-seconds)
    entry.inflight=copy(batch)
    local ok,save_error=pcall(self._save,self,state)
    if not ok then
        entry.pending=entry.pending+seconds
        entry.inflight=nil
        dirty_states[storage_key(self)]=copy(state)
        error(save_error)
    end
    reservations[reservation_key(self,account,book)]=batch
    return batch
end
function M:settle(batch,result)
    if not batch then return false end
    local state=self:_state()
    local entry=self:_entry(state,batch.account,batch.book,false)
    if not entry or not entry.inflight or entry.inflight.id~=batch.id then
        if dirty_states[storage_key(self)] then self:_save(state) end
        return false
    end
    local seconds=entry.inflight.seconds
    if result=='accepted' then entry.acknowledged=entry.acknowledged+seconds
    elseif result=='retryable' then entry.pending=entry.pending+seconds
    else add_uncertain(entry,seconds) end
    entry.inflight=nil
    local ok,err=pcall(self._save,self,state)
    local key=reservation_key(self,batch.account,batch.book)
    if reservations[key]==batch then reservations[key]=nil end
    if not ok then error(err) end
    return true
end
-- Position writes carry no elapsed time, but share the per-book network slot
-- with closed-book position sync and timer reports. Keep these locks in memory only.
function M:has_pending_report(account,book)
    return reservations[reservation_key(self,account,book)]~=nil
end
function M:lock_position(account,book)
    if account==nil or tostring(account)=='' or book==nil or tostring(book)=='' then
        return nil,'position_identity_missing'
    end
    local key=reservation_key(self,account,book)
    if reservations[key] then return nil,'time_report_busy' end
    self:recover(account)
    local lock={account=account,book=tostring(book),position=true}
    reservations[key]=lock
    return lock
end
function M:unlock_position(lock)
    if not lock then return end
    local key=reservation_key(self,lock.account,lock.book)
    if reservations[key]==lock then reservations[key]=nil end
end
-- Recover only abandoned requests for the signed-in account. A live parent
-- request retains its batch object, so another UI instance cannot steal it.
function M:recover(account)
    local state=self:_state()
    local books=(state.accounts or {})[tostring(account or '')] or {}
    local count=0
    for book,entry in pairs(books) do
        if entry.inflight and not reservations[reservation_key(self,account,book)] then
            add_uncertain(entry,entry.inflight.seconds)
            entry.inflight=nil
            count=count+1
        end
    end
    if count>0 or dirty_states[storage_key(self)] then self:_save(state) end
    return count
end
function M:status(account,book)
    local entry=self:_entry(self:_state(),account,book,false) or {}
    return {pending=entry.pending or 0,uncertain=entry.uncertain or 0,
        inflight=entry.inflight and entry.inflight.seconds or 0,acknowledged=entry.acknowledged or 0}
end
return M

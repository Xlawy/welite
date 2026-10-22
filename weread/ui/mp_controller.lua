-- Public-account navigation; fetching/parsing remain owned by the upstream client/content.
local List=require('weread.ui.welite.record_list')
local Content=require('weread.lib.content')
local Auth=require('weread.lib.worker_settings')
local _=require('weread.lib.i18n').tr
local M={}
function M.show(plugin,book,initial,force)
    if plugin._mp_session then plugin._mp_session:close() end
    local session={offset=0,history={}};plugin._mp_session=session
    local account=plugin.settings:get('account',{}).user_vid
    local fingerprint=Auth.fingerprint(plugin.settings)
    local function valid()
        return not session.closed and plugin.settings:get('account',{}).user_vid==account
            and Auth.fingerprint(plugin.settings)==fingerprint
    end
    function session:close()
        self.closed=true
        local worker=self.worker;self.worker=nil
        if worker then worker:cancel(nil,'mp_closed') end
        if plugin._mp_session==self then plugin._mp_session=nil end
        local view=self.view;self.view=nil
        if view and not view.closed then view:onClose() end
    end
    local load,render
    render=function(items,status,retry,batch_actions)
        local old=session.view;session.view=nil
        if old then old:onClose() end
        local view
        view=List.show({heading=book and book.title or _('Public Accounts'),
            items=items,status=status,batch_actions=batch_actions,empty_text=book and _('No articles.') or _('No items.'),
            action_text=book and _('Refresh article list') or _('Back')},{
            on_close=function() if session.view==view then session:close() end end,
            on_action=function() if book then load() else session:close() end end,
            on_retry=retry,
            on_select=function(item)
                if not valid() then session:close();return end
                if item.book then plugin:showMPAccount(item.book);return end
                local path=Content.mp_article_cached_path(plugin.settings,book,item.article)
                if path then plugin:openFile(path) else session:download(item.article) end
            end})
        session.view=view
    end
    local function articles(items)
        local rows={}
        for _index,article in ipairs(items) do
            local date=tonumber(article.createTime) or 0
            rows[#rows+1]={title=article.title,author=(date>0 and os.date('%Y-%m-%d',date) or '')
                ..(Content.mp_article_cached_path(plugin.settings,book,article) and ' · '.._('Cached') or ''),article=article}
        end
        local actions={}
        if #session.history>0 then
            actions[#actions+1]={text=_('Newer articles'),callback=function()
                load(nil,session.history[#session.history],'previous')
            end}
        end
        if session.next_offset then
            actions[#actions+1]={text=_('Older articles'),callback=function()
                load(nil,session.next_offset,'next')
            end}
        end
        render(rows,nil,nil,actions)
    end
    load=function(article,offset,direction)
        if not valid() then session:close();return end
        if session.worker or not plugin:requireLogin(true,false) then return end
        offset=offset or 0
        render(nil,article and _('Download article and read') or _('Loading articles...'))
        local worker=require('weread.lib.background_worker'):new{temp_dir=plugin.settings.data_dir..'/workers',timeout=article and 120 or 45}
        session.worker=worker
        local function retry() load(article,offset,direction) end
        local function failed()
            render(nil,article and _('Unable to download article. Please retry.') or _('Unable to load articles. Please retry.'),retry)
        end
        local started=worker:start{task=function(context)
            local capture=Auth.capture(plugin.settings)
            if article then
                local path=Content.fetch_mp_article_html(plugin.client,plugin.settings,book,article,{
                    check_cancelled=context.checkCancelled,
                    progress=function() context.checkCancelled() end,
                })
                context.checkCancelled()
                return {path=path,cache_dir=book.cache_dir,auth=capture()}
            end
            local function request()
                context.checkCancelled()
                local ticket=plugin.settings:get('wr_ticket','')
                return plugin.client:get_mp_articles(book.book_id or book.bookId,offset,100,ticket~='' and ticket or nil)
            end
            local data,code=request()
            if not data and (code==-2041 or code==-2012) then
                plugin.client:renew_cookie();data,code=request()
            end
            assert(type(data)=='table','mp articles: '..tostring(code))
            local groups=type(data.reviews)=='table' and #data.reviews or 0
            return {articles=Content.parse_mp_articles(data),next_offset=groups>0 and offset+groups or nil,auth=capture()}
        end,on_done=function(outcome)
            if session.closed or session.worker~=worker then return end
            session.worker=nil
            if not valid() then session:close();return end
            if not outcome.ok then
                session.error=outcome.error
                require('weread.lib.logger').warn('mp task failed:',require('weread.lib.plugin_util').log_error(outcome.error))
                if tostring(outcome.error):find('mp articles: %-20[14][12]') then
                    render(nil,_('WeRead could not refresh the public-account credential. Please scan the QR code again.'),retry)
                else failed() end
                return
            end
            Auth.merge(plugin.settings,fingerprint,outcome.value.auth)
            fingerprint=Auth.fingerprint(plugin.settings)
            session.error=nil
            if article then
                book.cache_dir=outcome.value.cache_dir
                plugin:rememberMPAccount(book)
                session:close()
                plugin:openFile(outcome.value.path)
                return
            end
            if direction=='next' then
                session.history[#session.history+1]=session.offset
                -- Keep only cursor history, never previous article bodies/rows.
                if #session.history>20 then table.remove(session.history,1) end
            elseif direction=='previous' then
                table.remove(session.history)
            else session.history={} end
            session.offset=offset
            session.next_offset=outcome.value.next_offset
            if offset==0 then plugin:cacheMPArticles(book.book_id or book.bookId,outcome.value.articles) end
            articles(outcome.value.articles)
        end}
        if not started and session.worker==worker then session.worker=nil;failed() end
    end
    function session:download(article)
        load(article)
    end
    if not book then
        local rows={}
        for _,entry in ipairs(plugin.shelf_mp or {}) do rows[#rows+1]={title=entry.title,author=entry.author,book=entry} end
        render(rows)
    else
        plugin:rememberMPAccount(book)
        local cached=initial or plugin:getCachedMPArticles(book.book_id or book.bookId)
        if not force and cached then articles(cached) else load() end
    end
    return session
end
function M.download(plugin,book,article)
    local session=M.show(plugin,book,{})
    session:download(article)
    return session
end
return M

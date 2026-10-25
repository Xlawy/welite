-- Compose the reader services around explicit host callbacks. State belongs to
-- ProgressSync and ReadReport; this module performs no reading or network I/O.
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local ReadReport = require("welite.lib.read_report")
local ProgressSync = require("welite.lib.progress_sync")
local _ = require("welite.lib.plugin_util").tr
local M = {}
function M.attach(self)
    self.read_report = ReadReport:new{
        time_ledger = require("welite.lib.reading_time_ledger").open(self.settings,function()
            local time=require("ui/time")
            return time.to_s(time.now())
        end),
        settings = self.settings,
        client = self.client,
        library_db = self.library_db,
        scheduler = UIManager,
        get_document = function()
            return self.ui and self.ui.document
        end,
        detect_book = function()
            return self:detectWeReadBook()
        end,
        position_provider = function(book_id)
            if not self.progress_sync then
                return nil, "progress_sync_initializing", true
            end
            return self.progress_sync:position_for_report(book_id)
        end,
        -- The report tick runs on the UI loop; use the link-state check here
        -- because NetworkMgr:isOnline() does a blocking DNS lookup.
        is_online = function()
            return self:isNetworkConnected()
        end,
    }
    self.progress_sync = ProgressSync:new{
        can_finish_close_upload = function()
            local active = require("apps/reader/readerui").instance
            return not active or active == self.ui
        end,
        settings = self.settings,
        client = self.client,
        scheduler = UIManager,
        get_document = function()
            return self.ui and self.ui.document
        end,
        get_footer = function()
            return self.ui and self.ui.view and self.ui.view.footer
        end,
        get_view_mode = function()
            return self.ui and self.ui.view and self.ui.view.view_mode or "page"
        end,
        detect_book = function()
            return self:detectWeReadBook()
        end,
        get_book = function(book_id)
            return self.settings:get_book(book_id)
        end,
        get_chapters = function(book)
            return self:ensureChaptersLoaded(book)
        end,
        refresh_catalog_async = function(book_id,done,valid)
            return require("welite.lib.progress_pull_worker").catalog(self,book_id,done,valid)
        end,
        get_file_context = function(book, path)
            return self:getChapterInfoFromFile(book, path)
        end,
        run_online = function(_kind, callback, run_options)
            return self:runOnlineTask(
                _("Sync progress"), callback, nil, run_options)
        end,
        upload_position_async = function(book_id, position, done, valid)
            return self.read_report:upload_position_async(book_id, position, done, valid)
        end,
        capture_local_snapshot = function(context, position)
            return require("welite.lib.progress_source_locator").snapshot(self,context,position)
        end,
        prepare_local_async = function(context, position, done, valid)
            return require("welite.lib.progress_source_locator").capture(self,context,position,done,valid)
        end,
        prepare_remote_async = function(context, remote, done, valid)
            return require("welite.lib.progress_source_locator").start(self,context,remote,done,valid)
        end,
        goto_xpointer = function(xp)
            return pcall(function() self.ui.rolling:onGotoXPointer(xp) end)
        end,
        goto_page = function(page)
            return pcall(function() self.ui.rolling:onGotoPage(page) end)
        end,
        goto_fraction = function(fraction)
            -- KOReader accepts fractional percentages. Rounding here loses
            -- several pages in long books before the host resolves a position.
            local percent = math.max(0, math.min(1, tonumber(fraction) or 0)) * 100
            return pcall(function()
                if self.ui and self.ui.rolling
                    and self.ui.rolling.onGotoPercent then
                    self.ui.rolling:onGotoPercent(percent)
                elseif self.ui then
                    self.ui:handleEvent(Event:new("GotoPercent", percent))
                else
                    error("reader unavailable")
                end
            end)
        end,
        open_chapter = function(book, chapter)
            return self:openProgressTargetChapter(book, chapter)
        end,
        is_online = function()
            return self:isNetworkConnected()
        end,
        on_choice = function(context)
            require("welite.ui.progress_sync_dialog").show_choice(context)
        end,
        run_pull = function(task, done, valid)
            return require("welite.lib.progress_pull_worker").start(self,task,done,valid)
        end,
        get_remote_chapter_fraction = function(book_id, remote)
            return require("welite.lib.progress_pull_worker").cached_chapter_fraction(self,book_id,remote)
        end,
        cancel_pull = function()
            require("welite.lib.progress_source_locator").cancel(self)
            require("welite.lib.progress_pull_worker").cancel(self)
        end,
        on_synced = function(book_id, account)
            require("welite.ui.welite.reading_sync").complete(self, book_id, account)
        end,
        notify = function(code, data)
            require("welite.ui.progress_sync_dialog").notify(code, data)
        end,
    }
end
return M

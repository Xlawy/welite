-- Reading-report settings, status, and statistics UI.
local logger = require("welite.lib.logger")
local ReadStats = require("welite.lib.read_stats")
local ReadStatsView = require("welite.ui.read_stats_view")
local UIManager = require("ui/uimanager")

local PluginUtil = require("welite.lib.plugin_util")
local _ = PluginUtil.tr
local T = PluginUtil.T
local log_error = PluginUtil.log_error
local display_error = PluginUtil.display_error

local M = {}

function M:getReadReportMenuItems()
    return {
        {
            text = _("Enable reading time report"),
            keep_menu_open = true,
            check_callback_updates_menu = true,
            checked_func = function()
                return self.settings:get("read_report").enabled
            end,
            callback = self:safeCallback(_("Enable reading time report"), function(touchmenu_instance)
                local cur = self.settings:get("read_report")
                cur.enabled = not cur.enabled
                self.settings:set("read_report", cur)
                self.settings:flush()
                if touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
                if cur.enabled then
                    self:maybeStartReadReport()
                else
                    self:stopReadReport()
                end
            end),
        },
        {
            text_func = function()
                local interval = tonumber(self.settings:get("read_report").interval_seconds) or 30
                return T(_("Report interval: %1 s"), interval)
            end,
            keep_menu_open = true,
            sub_item_table_func = function()
                return self:getReportIntervalMenuItems()
            end,
        },
        {
            text = _("Report status"),
            keep_menu_open = true,
            callback = self:safeCallback(_("Report status"), function()
                self:onShowWeLiteReportStatus()
            end),
        },

    }
end

-- Preset reporting intervals. A longer interval means fewer network wake-ups,
-- which matters on battery-powered e-ink devices.
function M:getReportIntervalMenuItems()
    local items = {}
    for _i, seconds in ipairs({ 30, 60 }) do
        local label = T(_("%1 seconds"), seconds)
        items[#items + 1] = {
            text = label,
            keep_menu_open = true,
            check_callback_updates_menu = true,
            checked_func = function()
                local current = tonumber(self.settings:get("read_report").interval_seconds) or 30
                return current == seconds
            end,
            callback = self:safeCallback(label, function(touchmenu_instance)
                local cur = self.settings:get("read_report")
                if (tonumber(cur.interval_seconds) or 30) == seconds then
                    return
                end
                cur.interval_seconds = seconds
                self.settings:set("read_report", cur)
                self.settings:flush()
                -- Hand the new interval to the running session instead of
                -- restarting it: a report already in flight is allowed to
                -- finish and write back its result.
                if self.read_report then
                    self.read_report:reschedule("interval_changed")
                end
                if touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
            end),
        }
    end
    return items
end

function M:onShowWeLiteReportStatus()
    local report_status = self.read_report:status()
    local title = report_status.target_book_title
    local target = title and T(_("Auto: %1"), title) or _("Auto-associate")
    local status = report_status.running and _("Running") or _("Stopped")
    local count = report_status.count
    local last = report_status.last_time
        and os.date("%H:%M:%S", report_status.last_time) or "--"
    local err = report_status.last_error or ""
    local msg = T(_("Report book: %1\nStatus: %2"), target, status)
        .. "\n" .. T(_("Reported: %1 times, last: %2"), tostring(count), last)
    local time_status=report_status.time_ledger
    if time_status then
        msg=msg.."\n"..T(_("Pending reading time: %1 s"),math.floor(time_status.pending or 0))
        if (time_status.uncertain or 0)>0 then
            msg=msg.."\n"..T(_("Unconfirmed reading time: %1 s (not retried)"),math.floor(time_status.uncertain))
        end
    end
    if err ~= "" then
        msg = msg .. "\n" .. T(_("Last error: %1"), err)
    end
    self:showInfo(msg)
    return true
end

function M:showReadStats()
    if not self:requireLogin(false, true) then
        return
    end
    -- Open on the monthly tab by default.
    self:loadReadStats("monthly", nil, nil)
end

-- Fetch reading statistics for a period and (re)show the visualization page.
-- old_view, when provided, is closed once the new data is ready (tab switch or
-- period navigation).
function M:loadReadStats(mode, base_time, old_view)
    self:showBusy(_("Loading reading statistics..."))
    self:runOnlineTask(_("Reading statistics"), function()
        local ok, data = pcall(function()
            return ReadStats.fetch(self.client, mode, base_time)
        end)
        self:closeBusy()
        if not ok then
            logger.err("load reading statistics failed:", log_error(data))
            self:showInfo(T(_("%1 failed:\n%2"), _("Reading statistics"), display_error(data)))
            return
        end
        if old_view then
            UIManager:close(old_view)
        end
        local view
        view = ReadStatsView.show(data, {
            on_prev = function()
                self:loadReadStats(mode, data.prev_base_time, view)
            end,
            on_next = function()
                self:loadReadStats(mode, data.next_base_time, view)
            end,
            on_switch = function(new_mode)
                self:loadReadStats(new_mode, nil, view)
            end,
        })
    end)
end

return M

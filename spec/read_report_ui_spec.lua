-- Reading-report controls always follow the current reader session.

package.path = "./?.lua;./?/init.lua;" .. package.path

package.preload["ui/uimanager"] = function() return {} end
package.preload["weread.lib.logger"] = function()
    return { err = function() end }
end
package.preload["weread.lib.read_stats"] = function() return {} end
package.preload["weread.ui.read_stats_view"] = function() return {} end
package.preload["weread.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        T = function(text, ...)
            local args = { ... }
            return (text:gsub("%%(%d+)", function(index)
                return tostring(args[tonumber(index)])
            end))
        end,
        log_error = tostring,
        display_error = tostring,
    }
end

local ReadReportUI = require("weread.ui.read_report")
local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

-- Even a stale in-memory legacy setting must not bring back target selection.
local config = { enabled = false, mode = "manual", book_id = "old-book", book_title = "Old Book" }
local stopped, started, rescheduled
local flushes = 0
local host = setmetatable({
    settings = {
        get = function(_self, key)
            if key == "read_report" then return config end
        end,
        set = function(_self, key, value)
            if key == "read_report" then config = value end
        end,
        flush = function() flushes = flushes + 1 end,
    },
    requireLogin = function() return true end,
    refreshBookshelf = function() error("report settings must not open a book picker") end,
    stopReadReport = function() stopped = true end,
    maybeStartReadReport = function() started = true end,
    read_report = {
        reschedule = function(_self, reason) rescheduled = reason end,
    },
    safeCallback = function(_self, _label, callback) return callback end,
}, { __index = ReadReportUI })

local report_items = host:getReadReportMenuItems()
expect(#report_items == 4, "only enable, interval, status and time review remain")
expect(report_items[1].keep_menu_open == true
        and report_items[2].keep_menu_open == true
        and report_items[3].keep_menu_open == true,
    "reading report actions keep their menu open")
expect(host.getReportTargetMenuItems == nil and host.showReadReportBookPicker == nil,
    "manual target selection must be removed")

local menu_refreshes = 0
local touchmenu = {
    updateItems = function()
        menu_refreshes = menu_refreshes + 1
    end,
}
report_items[1].callback(touchmenu)
expect(config.enabled == true and started == true and stopped == nil,
    "enabling must start the current reader session without asking for a target")
report_items[1].callback(touchmenu)
expect(config.enabled == false and stopped == true, "disabling stops the reader timer")
expect(flushes == 2, "both toggle changes must be saved")
expect(menu_refreshes == 2,
    "reading report toggles did not refresh the open menu")

-- Reporting interval presets: 30 s (default) and 60 s.
local interval_items = host:getReportIntervalMenuItems()
expect(#interval_items == 2, "report interval menu should offer two presets")
expect(interval_items[1].checked_func() == true,
    "report interval should fall back to 30 seconds when unset")
expect(interval_items[2].checked_func() == false,
    "60 seconds should not be selected by default")

config.enabled = true
stopped, started, rescheduled = nil, nil, nil
interval_items[2].callback(touchmenu)
expect(config.interval_seconds == 60,
    "selecting 60 seconds did not persist the interval")
expect(rescheduled == "interval_changed",
    "changing the interval did not hand it to the running report")
expect(stopped == nil and started == nil,
    "changing the interval must not stop and restart the report")
expect(interval_items[2].checked_func() == true,
    "60 seconds should be checked after selection")

-- Selecting the value that is already stored must be a no-op: it must not
-- touch the settings file nor disturb the running report.
rescheduled = nil
local stored_before = config.interval_seconds
local flushes_before = flushes
interval_items[2].callback(touchmenu)
expect(rescheduled == nil,
    "re-selecting the current interval must not reschedule the report")
expect(config.interval_seconds == stored_before,
    "re-selecting the current interval changed the stored value")
expect(flushes == flushes_before, "re-selecting the interval must not write settings")

local status_text
local report_status = { running = false, count = 0 }
host.read_report = { status = function() return report_status end }
host.showInfo = function(_self, text) status_text = text end
expect(host:onShowWeReadReportStatus(), "status gesture consumes the reader event")
expect(status_text == "Report book: Auto-associate\nStatus: Stopped\nReported: 0 times, last: --",
    "without an active reader the status must not show the legacy fixed target")
local gesture_text = status_text
status_text = nil
report_items[3].callback()
expect(status_text == gesture_text, "menu and gesture show the same report status")

report_status = {
    running = true, count = 3, target_book_title = "Auto Book",
    last_time = 12345, last_error = "offline",
}
host:onShowWeReadReportStatus()
expect(status_text == "Report book: Auto: Auto Book\nStatus: Running\nReported: 3 times, last: "
        .. os.date("%H:%M:%S", report_status.last_time) .. "\nLast error: offline",
    "status must show the live book even when a legacy manual target exists")

report_status.time_ledger={pending=42.5,uncertain=30}
host:onShowWeReadReportStatus()
expect(status_text:find("Pending reading time: 42 s",1,true), "pending duration missing")
expect(status_text:find("Unconfirmed reading time: 30 s (not retried)",1,true), "ambiguous duration hidden")


local reviewed=false
package.preload['weread.ui.reading_time_review']=function() return {show=function(plugin) reviewed=plugin==host end} end
report_items[4].callback()
expect(reviewed,'review menu must reach the account time-review controller')
print(("read_report_ui_spec: %d checks"):format(checks))

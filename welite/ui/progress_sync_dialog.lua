local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template
local util = require("util")

local I18n = require("welite.lib.i18n")

local ProgressSyncDialog = {}

local function _(text)
    return I18n.tr(text)
end

local function percent(position)
    return string.format("%.0f", tonumber(position and position.percent) or 0)
end

-- Display-only labels: never reinterpret a UTF-16 source offset as a word
-- count, or feed rounded percentages back into jump/upload coordinates.
local function compact(value, limit)
    if type(value) ~= "string" then return "" end
    local text = value:sub(1, 2048):gsub("[%c%s]+", " "):match("^%s*(.-)%s*$")
    local chars = util.splitToChars(text)
    local result = table.concat(chars, "", 1, math.min(#chars, limit))
    if #chars > limit or #value > 2048 then result = result .. "…" end
    return result
end

local function chapter(position, catalog)
    local entry = catalog and catalog.by_uid
        and catalog.by_uid[tostring(position.chapter_uid)]
    local node = entry and entry.source or {}
    local title = compact(node.title or node.chapterTitle, 40)
    if title ~= "" then return title end
    local index = tonumber(entry and entry.chapter_idx or position.chapter_idx)
    if index and index > 0 then return T(_("Chapter %1"), tostring(index)) end
    if position.chapter_uid ~= nil then
        return T(_("Chapter ID %1"), compact(tostring(position.chapter_uid), 24))
    end
    return _("Chapter unavailable")
end

local function position_text(position, context)
    position = position or {}
    local title = chapter(position, context.position_catalog)
    local fraction = tonumber(position.chapter_fraction)
    if fraction and fraction >= 0 and fraction <= 1 then
        local ratio = string.format("%.1f", fraction * 100):gsub("%.0$", "")
        return T(_("%1 · about %2% of chapter"), title, ratio)
    end
    return T(_("%1 · chapter progress unavailable"), title)
end

function ProgressSyncDialog.show_choice(context)
    local local_text = position_text(context.local_position, context)
    local remote_text = position_text(context.remote_position, context)
    local message
    if context.source_conflict then
        message = T(_(
            "WeRead's two progress sources disagree for \"%1\".\n\n"
            .. "KOReader: %2\n\nSelected cloud position: %3\n\n"
            .. "Choose which position to keep."
        ), compact(context.book_title, 28), local_text, remote_text)
    else
        message = T(_(
            "Reading progress differs for \"%1\".\n\n"
            .. "KOReader: %2\n\nWeRead: %3\n\n"
            .. "Choose which position to keep."
        ), compact(context.book_title, 28), local_text, remote_text)
    end

    local dialog = ConfirmBox:new{
        title = _("Reading progress sync"),
        text = message,
        ok_text = _("Use WeRead progress"),
        cancel_text = _("Cancel"),
        ok_callback = context.use_remote,
        cancel_callback = context.cancel or function() end,
        other_buttons = {{
            { text = _("Keep KOReader progress"), callback = context.keep_local },
        }},
    }
    UIManager:show(dialog)
    return dialog
end

function ProgressSyncDialog.notify(code, data)
    data = data or {}
    local text
    if code == "upload_success" then
        text = T(_("Progress uploaded to WeRead: %1%"),
            percent(data.position))
    elseif code == "upload_failed" then
        text = T(_("Progress upload failed:\n%1"), tostring(data.error or ""))
    elseif code == "already_synced" then
        text = _("KOReader and WeRead are already at the same position.")
    elseif code == "remote_applied" then
        text = T(_("Jumped to WeRead progress: %1%"),
            percent(data.position))
    elseif code == "local_kept" then
        text = _("Kept the current KOReader position.")
    elseif code == "pull_failed" then
        text = T(_("Could not fetch WeRead progress:\n%1"),
            tostring(data.error or ""))
    elseif code == "jump_failed" then
        text = T(_("Could not jump to WeRead progress:\n%1"),
            tostring(data.error or ""))
    elseif code == "local_unavailable" then
        text = T(_("Could not determine the current reading position:\n%1"),
            tostring(data.error or ""))
    elseif code == "authentication_required" then
        text = _("Please scan the QR code to log in first.")
    elseif code == "offline" then
        text = _("No network connection. Please connect Wi-Fi and try again.")
    else
        return
    end
    UIManager:show(InfoMessage:new{ text = text })
end

return ProgressSyncDialog

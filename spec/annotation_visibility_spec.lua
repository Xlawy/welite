-- Focused regression tests for the global annotation visibility toggle.

package.path = "./?.lua;" .. package.path

package.preload["welite.lib.annotations"] = function() return {} end
package.preload["welite.lib.content"] = function() return {} end
package.preload["ui/event"] = function()
    return { new = function(_self, name) return { name = name } end }
end
package.preload["welite.lib.logger"] = function()
    return { warn = function() end }
end
package.preload["welite.lib.thought_db"] = function() return {} end

local popup_close_count = 0
package.preload["welite.ui.thought_popup"] = function()
    return { closeVisible = function() popup_close_count = popup_close_count + 1 end }
end
package.preload["welite.ui.thought_popup.popup_config"] = function() return {} end
package.preload["ui/time"] = function() return {} end
package.preload["ui/uimanager"] = function()
    return { setDirty = function() end }
end
package.preload["welite.lib.plugin_util"] = function()
    return {
        tr = function(text) return text end,
        thought_perf = function() end,
    }
end

local Controller = require("welite.ui.annotations_controller")

local checks = 0
local function expect(value, message)
    checks = checks + 1
    if not value then error(message or ("check " .. checks .. " failed")) end
end

local cache = { show_annotations = true }
local ensure_count, apply_count, flush_count = 0, 0, 0
local notice
local host = {
    settings = {
        get = function(_self, key)
            if key == "cache" then return cache end
        end,
        set = function(_self, key, value)
            if key == "cache" then cache = value end
        end,
        flush = function() flush_count = flush_count + 1 end,
    },
    ensureAnnotationDisplay = function()
        ensure_count = ensure_count + 1
        return true
    end,
    applyAnnotationVisibility = function() apply_count = apply_count + 1 end,
    showTransientInfo = function(_self, text) notice = text end,
    _annotationSummary = function() return { chapters = 0 } end,
}
host.toggleAnnotationVisibility = Controller.toggleAnnotationVisibility

-- Hiding is always immediate, even when the current document has no matches.
host:toggleAnnotationVisibility()
expect(cache.show_annotations == false, "unmatched document could not disable the global setting")
expect(ensure_count == 0, "hiding annotations unexpectedly opened the matching guide")
expect(apply_count == 1 and flush_count == 1,
    "hidden state was not persisted and applied exactly once")
expect(popup_close_count == 1 and notice == "Underlines and thoughts hidden",
    "hiding did not close the popup or report the new state")

-- Showing persists the global choice first, then guides an unmatched document.
notice = nil
host:toggleAnnotationVisibility()
expect(cache.show_annotations == true, "showing did not persist the global setting")
expect(ensure_count == 1 and apply_count == 2 and flush_count == 2,
    "showing an unmatched document did not apply before opening the guide")
expect(notice == nil, "matching guide competed with a visibility notification")

-- Existing matches enable immediately without reopening the guide.
cache.show_annotations = false
host._annotation_context = {}
host._annotationSummary = function() return { chapters = 1 } end
host:toggleAnnotationVisibility()
expect(cache.show_annotations == true and ensure_count == 1,
    "matched document reopened the matching guide")
expect(notice == "Underlines and thoughts shown",
    "matched document did not report the shown state")

print(("annotation_visibility_spec: %d checks"):format(checks))

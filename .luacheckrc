std = "luajit"

globals = {
    "G_defaults",
    "G_reader_settings",
    "G_reader_ui",
}

-- KOReader callbacks intentionally leave some arguments unused, and a few
-- compatibility branches are deliberately empty.
ignore = {
    "212", -- unused argument
    "213", -- unused loop variable
    "581", -- preserve explicit boolean expressions used by menu callbacks
}

max_line_length = false

files["welite/lib/client.lua"] = {
    ignore = { "211/_status" },
}

files["welite/lib/i18n.lua"] = {
    -- Translation catalogs intentionally repeat a key in two grouped sections.
    ignore = { "314" },
}

files["welite/lib/plugin_util.lua"] = {
    ignore = { "143/table" },
}

files["welite/lib/progress_sync.lua"] = {
    ignore = {
        "211/_reason",
        "231/_index",
    },
}

files["welite/lib/protocol.lua"] = {
    ignore = { "311/width" },
}

files["welite/lib/reader_lifecycle.lua"] = {
    ignore = {
        "211/current_ch",
        "211/_started",
        "211/_title",
    },
}

files["welite/ui/annotations_controller.lua"] = {
    ignore = {
        "211/Annotations",
        "211/_current_idx",
    },
}

files["welite/ui/reader_navigation.lua"] = {
    ignore = { "211/current_ch" },
}

files["spec/scan_spec.lua"] = {
    ignore = { "211/d_added" },
}

files["spec/koreader/*.lua"] = {
    globals = {
        "describe",
        "setup",
        "teardown",
        "before_each",
        "after_each",
        "it",
        "disable_plugins",
        "load_plugin",
    },
}

-- Restore os.rename after each migration fault-injection case.
files["spec/koreader/welite_profile_store_spec.lua"] = { globals = { "os.rename" } }

-- Frozen UI reference fixtures: preserve their source hashes verbatim.
files["spec/reference/welite/pulldown.lua"] = { ignore = { "211/Center" } }
files["spec/reference/welite/shelf.lua"] = { ignore = { "431/w", "411/filtered", "421/line" } }

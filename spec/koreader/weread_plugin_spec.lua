-- This file is copied into KOReader's spec/front/unit tree by
-- scripts/run_koreader_integration.sh and runs with KOReader's own Busted setup.

describe("WeRead plugin integration", function()
    setup(function()
        require("commonrequire")
        disable_plugins()
    end)

    it("is discovered and loaded by KOReader PluginLoader", function()
        load_plugin("welite.koplugin")

        local PluginLoader = require("pluginloader")
        local plugin
        for _, candidate in ipairs(PluginLoader.enabled_plugins) do
            if candidate.name == "welite" then
                plugin = candidate
                break
            end
        end

        assert.is_table(plugin)
        assert.equals("welite", plugin.name)
        assert.equals("WeLite", plugin.fullname)
        assert.is_false(plugin.is_doc_only)
        assert.matches("welite%.koplugin$", plugin.path)
    end)

    it("exposes nine dispatcher actions with real plugin event handlers", function()
        local dispatcher = require("dispatcher")
        local original = dispatcher.registerAction
        local actions = {}
        dispatcher.registerAction = function(_, id, action)
            assert.is_nil(actions[id])
            actions[id] = action
        end
        local ok, err = pcall(function()
            require("welite.ui.menu"):onDispatcherRegisterActions()
            local plugin
            for _, candidate in ipairs(require("pluginloader").enabled_plugins) do
                if candidate.name == "welite" then plugin = candidate; break end
            end
            assert.is_table(plugin)
            local count = 0
            for _, action in pairs(actions) do
                count = count + 1
                local handler = plugin["on" .. action.event]
                -- PluginLoader wraps event handlers in callable HandlerSandbox tables.
                if type(handler) == "table" then
                    assert.is_function(getmetatable(handler).__call, action.event)
                    assert.is_function(handler.f, action.event)
                    assert.equals("on" .. action.event, handler.fname)
                else
                    assert.is_function(handler, action.event)
                end
                assert.is_truthy(action.reader or action.general)
                assert.is_truthy(action.title:find("WeLite", 1, true))
            end
            assert.equals(9, count)
        end)
        dispatcher.registerAction = original
        assert.is_true(ok, tostring(err))
    end)

    it("loads project modules only through the weread namespace", function()
        assert.is_table(package.loaded["welite.lib.client"])
        assert.is_table(package.loaded["welite.lib.settings"])
        assert.is_table(package.loaded["welite.ui.menu"])
        assert.is_nil(package.loaded["lib.client"])
        assert.is_nil(package.loaded["lib.settings"])
        assert.is_nil(package.loaded["ui.menu"])
    end)
end)

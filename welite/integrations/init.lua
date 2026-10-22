-- Optional integrations with third-party KOReader interfaces.

local logger = require("welite.lib.logger")

local Integrations = {}
local modules = {
    require("welite.integrations.zenui"),
}

function Integrations.register(plugin)
    for _i, integration in ipairs(modules) do
        local ok, err = pcall(function()
            integration:register(plugin)
        end)
        if not ok then
            logger.warn("welite: failed to register integration:",
                integration.name, tostring(err))
        end
    end
end

function Integrations.onZenUIReady(plugin)
    for _i, integration in ipairs(modules) do
        if integration.onZenUIReady then
            local ok, err = pcall(function()
                integration:onZenUIReady(plugin)
            end)
            if not ok then
                logger.warn("welite: ZenUIReady integration failed:",
                    integration.name, tostring(err))
            end
        end
    end
end

return Integrations

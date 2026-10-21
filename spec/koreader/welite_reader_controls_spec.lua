describe('WeLite reader panel bridge',function()
    local Bridge,UI,plugin
    setup(function() require('commonrequire');package.path='plugins/weread.koplugin/?.lua;'..package.path
        Bridge=require('weread.ui.welite.reader_controls');UI=require('ui/uimanager') end)
    after_each(function() if plugin then Bridge.close(plugin) end end)
    it('registers the original top tap/swipe/drag and retains horizontal gestures',function()
        local zones,opened
        plugin={ui={registerTouchZones=function(_,value) zones=value end}}
        Bridge.install(plugin)
        assert.equals('swipe',zones[1].ges);assert.equals(0.12,zones[1].screen_zone.ratio_h)
        assert.is_false(zones[1].handler{direction='west'})
        assert.equals('tap',zones[2].ges)
        assert.is_false(zones[3].handler{direction='west',start_pos={y=1}})
        assert.is_false(zones[4].handler{})
        assert.is_true(zones[3].handler{direction='south',start_pos={y=1}})
        assert.is_false(Bridge.show(plugin))
        plugin.ui.document={info={number_of_pages=200}}
        plugin.ui.rolling={current_page=12}
        plugin.onShowWeReadQuickMenu=function() opened=true end
        assert.is_true(zones[1].handler{direction='south'})
        local panel=plugin.welite_reader_panel;UI:forceRePaint()
        assert.is_true(Bridge.show(plugin));assert.equals(panel,plugin.welite_reader_panel)
        panel.buttons[5].callback();assert.is_truthy(plugin.welite_settings_ui.dialog);assert.is_nil(plugin.welite_reader_panel)
    end)
end)

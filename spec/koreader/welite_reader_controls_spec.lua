describe('WeLite reader panel bridge',function()
    local Bridge,UI,plugin
    setup(function() require('commonrequire');package.path='plugins/welite.koplugin/?.lua;'..package.path
        Bridge=require('welite.ui.welite.reader_controls');UI=require('ui/uimanager') end)
    after_each(function() if plugin then Bridge.close(plugin) end end)
    it('shows progress state and sends the panel action to real progress sync',function()
        local status={state='unverified'}
        local calls=0
        plugin={ui={document={info={number_of_pages=200}}},
            progress_sync={status=function() return status end},
            onWeLiteSyncProgress=function() calls=calls+1 end}
        assert.equals('同步进度',Bridge.syncStatus(plugin))
        Bridge.show(plugin)
        plugin.welite_reader_panel.sync_button.callback()
        assert.equals(1,calls)
        assert.is_nil(plugin.welite_reader_panel)
        status={state='verified',verified=true,dirty=true}
        assert.equals('待上传',Bridge.syncStatus(plugin))
        status.dirty=false
        assert.equals('已同步',Bridge.syncStatus(plugin))
        status={state='error'}
        assert.equals('同步失败',Bridge.syncStatus(plugin))
    end)
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
        plugin.onShowWeLiteQuickMenu=function() opened=true end
        assert.is_true(zones[1].handler{direction='south'})
        local panel=plugin.welite_reader_panel;UI:forceRePaint()
        assert.is_true(Bridge.show(plugin));assert.equals(panel,plugin.welite_reader_panel)
        assert.is_nil(opened)
        panel.buttons[5].callback();assert.is_truthy(plugin.welite_settings_ui.dialog);assert.is_nil(plugin.welite_reader_panel)
    end)
    it('dispatches top swipes and drags before native reader zones',function()
        local Container=require('ui/widget/container/inputcontainer')
        local Geom=require('ui/geometry')
        local Screen=require('device').screen
        local native_calls=0
        local reader=Container:new{}
        reader.document={info={number_of_pages=200}}
        plugin={ui=reader}
        local function register_native()
            local zones={}
            for _,entry in ipairs({{'rolling_swipe','swipe'},{'paging_swipe','swipe'},
                {'readermenu_swipe','swipe'},{'readermenu_ext_swipe','swipe'},
                {'rolling_pan','pan'},{'paging_pan','pan'},{'readermenu_pan','pan'},
                {'readermenu_ext_pan','pan'},{'rolling_pan_release','pan_release'},
                {'paging_pan_release','pan_release'}}) do
                zones[#zones+1]={id=entry[1],ges=entry[2],
                    screen_zone={ratio_x=0,ratio_y=0,ratio_w=1,ratio_h=1},
                    handler=function() native_calls=native_calls+1;return true end}
            end
            reader:registerTouchZones(zones)
        end
        local function gesture(kind,direction,y,start_y)
            return {ges=kind,direction=direction,pos=Geom:new{x=Screen:getWidth()/2,y=y,w=0,h=0},
                start_pos=start_y and Geom:new{x=Screen:getWidth()/2,y=start_y,w=0,h=0}}
        end
        register_native();Bridge.install(plugin)
        assert.is_true(reader:onGesture(gesture('swipe','south',1)))
        assert.is_truthy(plugin.welite_reader_panel)
        assert.equals(0,native_calls)
        Bridge.close(plugin)
        -- Native modules can register again on reader-ready or screen resize.
        register_native()
        assert.is_true(reader:onGesture(gesture('pan','south',Screen:getHeight()/2,1)))
        assert.is_true(reader:onGesture(gesture('pan_release',nil,Screen:getHeight()/2)))
        assert.is_truthy(plugin.welite_reader_panel)
        assert.equals(0,native_calls)
        Bridge.close(plugin)
        reader:onGesture(gesture('swipe','west',1))
        reader:onGesture(gesture('swipe','south',Screen:getHeight()/2))
        reader:onGesture(gesture('pan','south',Screen:getHeight()/2,Screen:getHeight()/3))
        assert.equals(3,native_calls)
        assert.is_nil(plugin.welite_reader_panel)
        reader:free()
    end)
end)

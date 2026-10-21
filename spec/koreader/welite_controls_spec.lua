describe('welite device control boundary',function()
    local C
    setup(function() require('commonrequire');package.path='plugins/weread.koplugin/?.lua;'..package.path;C=require('weread.ui.welite.controls') end)
    it('opens the owning plugin settings without creating a reading or network session',function()
        local opened=0
        local c=C.new({welite={showSettings=function() opened=opened+1 end}})
        assert.is_true(c:weliteSettings());assert.equals(1,opened)
        assert.is_false(C.new(nil):weliteSettings())
    end)
    it('uses cached radio status without scanning and disables unsupported hardware',function()
        local d={hasWifiToggle=function() return false end,hasBattery=function() return false end,hasFrontlight=function() return false end}
        local c=C.new(nil,{device=d,network={getNetworkList=function() error('must not scan') end},settings={isTrue=function() return false end}})
        local s=c:snapshot();assert.is_false(s.light_supported)
        assert.is_false(c:brightness(70));assert.is_false(c:light());assert.is_false(c:wifi(true));assert.is_false(c:settingsMenu())
    end)
    it('converts native brightness ranges and preserves intensity across off/on',function()
        local p={fl_min=0,fl_max=24,fl_intensity=12,on=true,isFrontlightOn=function(self) return self.on end,
            setIntensity=function(self,v) self.fl_intensity=v;self.on=v>0 end,toggleFrontlight=function(self) self.on=not self.on end}
        local d={hasWifiToggle=function() return true end,hasBattery=function() return false end,hasFrontlight=function() return true end,getPowerDevice=function() return p end}
        local c=C.new(nil,{device=d,network={},settings={isTrue=function() return false end}})
        assert.equals(50,c:snapshot().brightness);c:light();assert.equals(12,p.fl_intensity)
        assert.is_false(c:brightness(90));c:light();assert.is_true(p.on)
        c:brightness(75);assert.equals(18,p.fl_intensity);c:step(1);assert.equals(19,p.fl_intensity);c:step(-1);assert.equals(18,p.fl_intensity);c:brightness(150);assert.equals(24,p.fl_intensity)
        c:brightness(0);assert.is_false(p.on);c:light();assert.equals(1,p.fl_intensity)
    end)
    it('delegates explicit wifi operations and full refresh without network coupling',function()
        local calls={};local n={is_wifi_on=true,toggleWifiOff=function() calls.off=true end,
            toggleWifiOn=function(_,cb,select,interactive) calls.select=select;assert.is_true(interactive) end}
        local c=C.new({menu={onShowMenu=function() calls.menu=true end}},{device={hasWifiToggle=function() return true end,isAndroid=function() return false end},network=n,
            ui={setDirty=function(_,target,mode) assert.equals('all',target);assert.equals('full',mode);calls.refresh=true end}})
        c.radio={scan=function() calls.scan=true;return true end}
        c:wifi(false);assert.is_true(calls.off);c:wifi(true);assert.is_true(calls.scan)
        n.is_wifi_on=false;c:wifi(false);assert.is_false(calls.select)
        c:refresh();assert.is_true(calls.refresh);c:settingsMenu();assert.is_true(calls.menu)
    end)
    it('reads current native progress and scopes chapter-only page counts',function()
        local ui={document={info={number_of_pages=20}},rolling={current_page=5,getLastPercent=function() return .23 end},
            toc={getTocTitleByPage=function(_,page) assert.equals(5,page);return '第五章' end}}
        local s=C.reading(ui,{full=false,item={title='围城'}})
        assert.equals('23%',s.percent);assert.equals('本章 5 / 20 页',s.pages);assert.equals('第五章',s.chapter)
        assert.equals('全书 5 / 20 页',C.reading(ui,{full=true}).pages)
        ui.document.info.number_of_pages=0;assert.equals('—',C.reading(ui).percent)
        assert.is_nil(C.reading({}))
    end)
end)

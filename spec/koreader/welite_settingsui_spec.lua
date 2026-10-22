describe('welite native settings dialogs',function()
    local S,P,UI,settings,path,dialog,old_language
    setup(function()
        require('commonrequire');package.path='plugins/welite.koplugin/?.lua;'..package.path
        S=require('weread.ui.welite.settingsui');P=require('weread.ui.welite.preferences');UI=require('ui/uimanager')
    end)
    before_each(function() old_language=G_reader_settings:readSetting('language');path=os.tmpname();os.remove(path);settings=require('luasettings'):open(path);dialog=S.new{settings=settings} end)
    after_each(function() G_reader_settings:saveSetting('language',old_language);dialog:close();os.remove(path);os.remove(path..'.old') end)
    it('persists first-install acceptance and refusal and opens only on acceptance',function()
        local opens=0
        dialog:askStartup(function() opens=opens+1 end)
        dialog.dialog.buttons[2][1].callback()
        assert.is_false(P.read(settings).autostart);assert.is_true(P.read(settings).decided);assert.equals(0,opens)
        dialog:askStartup(function() opens=opens+1 end);dialog.dialog.buttons[1][1].callback()
        assert.is_true(P.read(settings).autostart);assert.equals(1,opens);assert.is_nil(dialog.dialog)
    end)
    it('edits the timezone, restores system time and toggles startup using actual widgets',function()
        dialog:show();UI:forceRePaint()
        dialog.dialog.buttons[2][1].callback();assert.is_true(P.read(settings).autostart)
        dialog.dialog.buttons[1][1].callback();dialog.dialog.buttons[2][1].callback()
        dialog.dialog:setInputText('+05:45');dialog.dialog.buttons[1][2].callback()
        assert.equals(345,P.read(settings).offset)
        assert.is_truthy(dialog.dialog.buttons[1][1].text:find('UTC+05:45',1,true))
        dialog.dialog.buttons[1][1].callback();dialog.dialog.buttons[1][1].callback()
        assert.is_nil(P.read(settings).offset)
        local output=os.getenv('WELITE_SCREENSHOT');UI:forceRePaint()
        if output then require('device').screen.bb:writePNG(output:gsub('plugin%-smoke','welite-settings')) end
    end)
    it('returns to the native host without quitting or changing startup preferences',function()
        local host=require('ui/widget/infomessage'):new{text='KOReader host'}
        local Library=require('weread.ui.library')
        local plugin={ui=host,closeWeReadUI=Library.closeWeReadUI,
            getMainMenuItems=function() return {} end}
        dialog.plugin=plugin
        P.save({autostart=true},settings)
        UI:show(host)
        local shelf=require('weread.ui.welite.shelf_adapter').show({mode='books',books={},
            welite_host=host,welite_plugin=plugin},{})
        plugin.shelf_view=shelf
        shelf:onQuickMenu()
        local ok,err=pcall(function()
            dialog:show()
            local button=dialog.dialog.buttons[#dialog.dialog.buttons-1][1]
            assert.equals('退出到 KOReader',button.text)
            button.callback()
            assert.equals(host,UI:getTopmostVisibleWidget())
            assert.is_nil(plugin.shelf_view)
            assert.is_nil(shelf.clock_timer)
            assert.is_nil(shelf.quick_menu)
            assert.is_nil(dialog.dialog)
            assert.is_true(P.read(settings).autostart)
        end)
        UI:close(shelf);UI:close(host)
        assert.is_true(ok,tostring(err))
    end)
    it('groups settings without duplicate entries and preserves upstream actions and navigation',function()
        G_reader_settings:saveSetting('language','zh_CN')
        local Menu=require('weread.ui.menu')
        local Report=require('weread.ui.read_report')
        local tr=require('weread.lib.i18n').tr
        settings:saveSetting('sync',{pull_on_open=false,upload_on_close=false})
        settings:saveSetting('cache',{download_book_images=true})
        local authenticated,login_checks=false,0
        local plugin=setmetatable({ui={},version='1.0.0',
            closeWeReadUI=require('weread.ui.library').closeWeReadUI,
            updater={available_version=function() return nil end},
            isAnnotationPrefetchEnabled=function() return false end,
            requireLogin=function() login_checks=login_checks+1;return authenticated end,
            settings={
                get=function(_,key,default) return settings:readSetting(key,default or {}) end,
                get_download_dir=function() return '/tmp/books' end,
                set=function(_,key,value) settings:saveSetting(key,value) end,
                flush=function() settings:flush() end},
            safeCallback=function(_,_,callback) return callback end},
            {__index=function(_,key) return Menu[key] or Report[key] end})
        dialog.plugin=plugin
        local menu=dialog:showUnified()
        local function find(items,label)
            for _,item in ipairs(items) do if item.text==label then return item end end
            error('missing setting: '..label)
        end
        local function back() dialog.dialog.buttons[#dialog.dialog.buttons][1].callback() end
        local root=menu.item_table
        local expected={'基础设置','同步与阅读时间','下载与存储','阅读与批注','账号管理','关于与高级'}
        assert.equals(6,#root)
        for i,label in ipairs(expected) do assert.equals(label,root[i].text) end
        assert.equals(8,#dialog.dialog.buttons,'root includes a separate exit action')
        local screen=require('device').screen
        UI:forceRePaint()
        assert.equals(0xCC,screen.bb:getPixel(0,0):getColor8().a)
        dialog.dialog:paintTo(screen.bb,0,0)
        assert.equals(0xCC,screen.bb:getPixel(0,0):getColor8().a,'repaint must not darken the backing')
        local output=os.getenv('WELITE_SCREENSHOT')
        UI:forceRePaint()
        if output then require('device').screen.bb:writePNG(output:gsub('plugin%-smoke','welite-unified-settings')) end

        menu:onMenuSelect(root[3])
        assert.equals(8,#menu.item_table,'prefetch and cache are flattened without duplicate categories')
        find(menu.item_table,tr('Automatically prefetch next chapter'))
        find(menu.item_table,tr('Cache cleanup'))
        local images=find(menu.item_table,tr('Book images'))
        menu:onMenuSelect(images)
        assert.is_false(settings:readSetting('cache').download_book_images)
        assert.is_truthy(dialog.dialog.buttons[1][1].text:find('关闭',1,true))
        dialog.dialog.buttons[#dialog.dialog.buttons-1][3].callback()
        assert.equals(2,menu.page)
        back();assert.equals(root,menu.item_table)

        menu:onMenuSelect(root[4])
        assert.equals(8,#menu.item_table,'popup preferences share the reading category')
        find(menu.item_table,tr('Font size'));back()
        menu:onMenuSelect(root[5])
        assert.equals(3,#menu.item_table,'login and account status are a single entry')
        assert.equals('login',menu.item_table[1].welite_id);back()
        menu:onMenuSelect(root[6])
        assert.equals('版本 v1.0',menu.item_table[1].text)
        assert.equals('作者：Xlawy',menu.item_table[2].text)
        assert.is_false(menu.item_table[1].enabled)
        assert.is_nil(menu.item_table[1].callback)
        assert.equals('开源感谢',menu.item_table[3].text)
        menu:onMenuSelect(menu.item_table[1]);assert.equals('关于与高级',menu.title)
        menu:onMenuSelect(menu.item_table[3])
        local credits=UI._window_stack[#UI._window_stack].widget
        assert.is_truthy(credits.text:find('finlater',1,true))
        assert.is_truthy(credits.text:find('AGPL-3.0-only',1,true))
        UI:forceRePaint()
        if output then require('device').screen.bb:writePNG(output:gsub('plugin%-smoke','welite-credits')) end
        UI:close(credits)
        UI:forceRePaint()
        if output then require('device').screen.bb:writePNG(output:gsub('plugin%-smoke','welite-about')) end
        find(menu.item_table,tr('Check for updates'));find(menu.item_table,tr('Mock service'));back()

        menu:onMenuSelect(root[2])
        assert.equals(8,#menu.item_table,'progress and reading time are in the same category')
        assert.equals(0,login_checks,'opening preferences must not prompt for authentication')
        local interval
        for _,item in ipairs(menu.item_table) do
            if item.sub_item_table_func and item.text_func then interval=item;break end
        end
        local sync_items=menu.item_table
        menu:onMenuSelect(interval)
        assert.equals(1,login_checks);assert.equals(sync_items,menu.item_table)
        authenticated=true;menu:onMenuSelect(interval)
        assert.equals(2,#menu.item_table);back()
        local toggle=find(menu.item_table,tr('Upload progress on close'))
        menu:onMenuSelect(toggle)
        assert.is_true(require('luasettings'):open(path):readSetting('sync').upload_on_close)
        assert.equals(menu,dialog.menu)
        UI:forceRePaint()
        if output then require('device').screen.bb:writePNG(output:gsub('plugin%-smoke','welite-unified-progress-settings')) end
        back();menu:onMenuSelect(root[1])
        dialog.dialog.buttons[1][1].callback()
        assert.equals('跟随系统',dialog.dialog.buttons[1][1].text)
        dialog.dialog.buttons[3][1].callback()
        assert.equals('基础设置',dialog.menu.title,'timezone returns to its parent category')
        back();assert.equals('WeLite 设置',dialog.menu.title)
        local stale=dialog.menu
        local calls=0
        stale:onMenuSelect{enabled_func=function() return false end,callback=function() calls=calls+1 end}
        assert.equals(0,calls)
        UI:close(dialog.dialog)
        assert.is_nil(dialog.dialog)
        stale:onMenuSelect{callback=function() calls=calls+1 end}
        stale:updateItems();assert.equals(0,calls);assert.is_nil(dialog.dialog)
    end)
end)

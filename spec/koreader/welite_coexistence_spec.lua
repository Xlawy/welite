-- Real upstream v1.6.0 sources are extracted from a pinned ancestor by the runner.
-- Neither plugin, its Settings nor its updater is mocked.
describe('WeLite and upstream WeRead coexistence',function()
    local Loader,Storage,LuaSettings,lfs,root,full,settings_dir,paths,loaded,dispatcher,register
    local old_enabled,old_disabled,old_instances,language,orders
    setup(function()
        require('commonrequire')
        Loader=require('pluginloader');Storage=require('datastorage');LuaSettings=require('luasettings')
        lfs=require('libs/libkoreader-lfs');dispatcher=require('dispatcher')
    end)
    before_each(function()
        root=os.tmpname();os.remove(root);assert(lfs.mkdir(root));assert(lfs.mkdir(root..'/settings'))
        full,settings_dir=Storage.getFullDataDir,Storage.getSettingsDir
        Storage.getFullDataDir=function() return root end
        Storage.getSettingsDir=function() return root..'/settings' end
        language=G_reader_settings:readSetting('language');G_reader_settings:saveSetting('language','C')
        old_enabled,old_disabled,old_instances=Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins
        Loader.enabled_plugins={};Loader.disabled_plugins={};Loader.loaded_plugins={}
        paths=package.path;loaded={}
        for name,value in pairs(package.loaded) do
            if name:match('^welite%.') or name:match('^weread%.') or name:match('^integrations%.') then
                loaded[name]=value;package.loaded[name]=nil
            end
        end
        orders={}
        for _,name in ipairs({'ui/elements/filemanager_menu_order','ui/elements/reader_menu_order'}) do
            local m=require(name);orders[name]=m.tools
            local copy={};for i,v in ipairs(m.tools) do copy[i]=v end;m.tools=copy
        end
        register=dispatcher.registerAction
        local actions={}
        dispatcher.registerAction=function(_,id,action)
            assert.is_nil(actions[id],'dispatcher ID collision: '..id)
            actions[id]=action
        end
        local old=LuaSettings:open(root..'/settings/weread.lua')
        old:saveSetting('auth_schema_version',1);old:saveSetting('welite_cache_layout',1)
        old:saveSetting('api_key','fixture-key');old:saveSetting('cookies',{wr_vid='42',wr_skey='fixture-cookie'})
        old:saveSetting('account',{user_vid='42',login_method='qr',login_time=1})
        old:saveSetting('update',{auto_check=false,available_version='1.6.0',release_notes='upstream notes'})
        old:saveSetting('books',{['7']={cache_dir=root..'/welite/cache/7'}});old:flush()
        require('util').makePath(root..'/welite/cache/7')
        local f=assert(io.open(root..'/welite/cache/7/reading_state.json','w'))
        f:write('{"progress":0.42,"chapter_uid":7,"chapter_offset":39}');f:close()
    end)
    after_each(function()
        dispatcher.registerAction=register
        Storage.getFullDataDir,Storage.getSettingsDir=full,settings_dir
        G_reader_settings:saveSetting('language',language)
        Loader.enabled_plugins,Loader.disabled_plugins,Loader.loaded_plugins=old_enabled,old_disabled,old_instances
        package.path=paths
        for name in pairs(package.loaded) do
            if name:match('^welite%.') or name:match('^weread%.') or name:match('^integrations%.') then package.loaded[name]=nil end
        end
        for name,value in pairs(loaded) do package.loaded[name]=value end
        for name,value in pairs(orders) do require(name).tools=value end
        require('ffi/util').purgeDir(root)
    end)
    for _,first in ipairs({'welite','weread'}) do
        it('keeps modules, menus, updater targets and login separate when '..first..' loads first',function()
            local upstream=assert(os.getenv('WELITE_UPSTREAM_FIXTURE'),'run through make test with pinned upstream fixture')
            local roots={welite='plugins/welite.koplugin',weread=upstream}
            local names=first=='welite' and {'welite','weread'} or {'weread','welite'}
            local entries={}
            for _,name in ipairs(names) do
                local path=roots[name]
                entries[#entries+1]={name=name,path=path,main=path..'/main.lua',meta=path..'/_meta.lua',disabled=false}
            end
            Loader:_load(entries)
            assert.equals(2,#Loader.enabled_plugins)
            for _,entry in ipairs(entries) do package.path=package.path..';'..entry.path..'/?.lua' end
            local ui={menu={registerToMainMenu=function() end}}
            local instances={}
            for _,p in ipairs(Loader.enabled_plugins) do
                local ok,instance=Loader:createPluginInstance(p,{ui=ui})
                assert.is_true(ok,tostring(instance))
                require('apps/filemanager/filemanager').registerModule(ui,p.name,instance)
                instances[p.name]=instance
            end
            local w,r=instances.welite,instances.weread
            assert.equals(w,ui.welite);assert.equals(r,ui.weread)
            assert.equals(require('welite.identity').version,w.version);assert.equals('1.6.0',r.version)
            assert.are_not.equal(require('welite.lib.updater'),require('weread.lib.updater'))
            assert.are_not.equal(require('welite.integrations.init'),require('integrations.init'))
            assert.equals(roots.welite,w.updater.updater.plugin_dir)
            assert.equals(roots.weread,r.updater.updater.plugin_dir)
            local menus={};w:addToMainMenu(menus);r:addToMainMenu(menus)
            assert.equals('WeLite',menus.welite.text);assert.equals('WeRead',menus.weread.text)
            assert.matches(w.version,w:getAboutMenuItems()[1].text,1,true)
            assert.matches('1.6.0',r:getAboutMenuItems()[1].text,1,true)
            assert.is_truthy(w.onWeLiteSyncProgress);assert.is_nil(w.onWeReadSyncProgress)
            assert.is_truthy(r.onWeReadSyncProgress);assert.is_nil(r.onWeLiteSyncProgress)
            assert.equals('welite.bookshelf',require('welite.integrations.zenui').item_id)
            assert.equals('weread.bookshelf',require('integrations.zenui').item_id)
            assert.equals(root..'/settings/welite-state.lua',w.settings.settings_file)
            assert.equals(root..'/settings/weread.lua',r.settings.settings_file)
            assert.equals('fixture-key',w.settings:get('api_key'))
            assert.same({wr_vid='42',wr_skey='fixture-cookie'},w.settings:get('cookies'))
            local book=w.settings:get('books')['7']
            assert.equals(0.42,book.progress);assert.equals(39,book.chapter_offset)
            assert.is_false(w.updater:has_update())
            local json=require('json')
            for _,instance in ipairs({w,r}) do
                local core=instance.updater.updater
                local is_welite=instance==w
                local repo=is_welite and 'Xlawy/welite' or 'finlater/weread.koplugin'
                local archive=(is_welite and 'welite' or 'weread')..'.koplugin-v9.0.0.zip'
                local base='https://github.com/'..repo..'/releases/download/v9.0.0/'
                local requests=0
                core._http_get=function(_,url)
                    requests=requests+1
                    assert.equals('https://api.github.com/repos/'..repo..'/releases/latest',url)
                    return json.encode{tag_name='v9.0.0',assets={
                        {name=archive,browser_download_url=base..archive},
                        {name=archive..'.sha256',browser_download_url=base..archive..'.sha256'}}}
                end
                local state=instance.settings:get('update');state.prefer_proxy=false
                instance.settings:set('update',state)
                local release=assert(core:fetch_release());core:cache_release(release)
                assert.equals(1,requests)
                assert.equals(base..archive,core:cached_release().archive_url)
            end
            assert.equals('Xlawy/welite',w.settings:get('update').source)
            assert.matches('finlater',r.settings:get('update').archive_url)
            w.settings:reset_account();w.settings:flush()
            assert.equals('fixture-key',LuaSettings:open(r.settings.settings_file):readSetting('api_key'))
            r.settings:flush()
            assert.equals('',LuaSettings:open(w.settings.settings_file):readSetting('api_key'))
        end)
    end
end)

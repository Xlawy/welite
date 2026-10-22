describe('WeLite profile migration', function()
    local P, LuaSettings, lfs, root, source, target, flush, rename, attributes
    local function read(path)
        local f=assert(io.open(path,'rb'));local s=f:read('*a');f:close();return s
    end
    setup(function()
        require('commonrequire')
        package.path='plugins/welite.koplugin/?.lua;'..package.path
        P=require('welite.lib.profile_store');LuaSettings=require('luasettings')
        lfs=require('libs/libkoreader-lfs')
    end)
    before_each(function()
        root=os.tmpname();os.remove(root);assert(lfs.mkdir(root))
        source=root..'/weread.lua';target=root..'/welite-state.lua'
        local old=LuaSettings:open(source)
        for k,v in pairs({auth_schema_version=1,device_fingerprint='1234',api_key='fixture-key',
            cookies={wr_vid='42',wr_skey='fixture-cookie'},wr_ticket='fixture-ticket',wr_wrpa='fixture-wrpa',
            account={user_vid='42',login_method='qr'},books={['7']={cache_dir='/existing/welite/cache/7'}},
            welite_pending_progress_sync={books={['7']={account='42',position={offset=39}}}},
            update={auto_check=true,prefer_proxy=false,available_version='1.6.0',last_check=9999999999,
                skipped_version='1.6.0',release_notes='foreign notes'},welite_cache_layout=1}) do
            old:saveSetting(k,v)
        end
        old:flush()
        flush,rename,attributes=LuaSettings.flush,os.rename,lfs.attributes
    end)
    after_each(function()
        LuaSettings.flush,os.rename,lfs.attributes=flush,rename,attributes
        require('ffi/util').purgeDir(root)
    end)
    it('copies login and reading indexes once, without modifying the source or scanning downloads',function()
        local before=read(source)
        local dir=lfs.dir;lfs.dir=function() error('migration must not scan directories') end
        local ok,new=pcall(P.open,target,source);lfs.dir=dir;assert.is_true(ok,tostring(new))
        local old=LuaSettings:open(source)
        for _,key in ipairs({'auth_schema_version','device_fingerprint','api_key','cookies','wr_ticket',
            'wr_wrpa','account','books','welite_pending_progress_sync','welite_cache_layout'}) do
            assert.same(old:readSetting(key),new:readSetting(key),key)
        end
        assert.same({source='Xlawy/welite',auto_check=true,prefer_proxy=false},new:readSetting('update'))
        assert.equals(before,read(source))
        new:saveSetting('api_key','');new:saveSetting('cookies',{});new:flush()
        old:saveSetting('api_key','different-upstream-account');old:flush()
        local again=P.open(target,source)
        assert.equals('',again:readSetting('api_key'))
        assert.same({},again:readSetting('cookies'))
        assert.equals('different-upstream-account',LuaSettings:open(source):readSetting('api_key'))
    end)
    it('recovers a readable legacy backup and rejects two corrupted copies',function()
        assert(os.rename(source,source..'.old'))
        local f=assert(io.open(source,'w'));f:write('not a lua table');f:close()
        assert.equals('fixture-key',P.open(target,source):readSetting('api_key'))
        os.remove(target);os.remove(source..'.old')
        assert.has_error(function() P.open(target,source) end)
        assert.is_nil(lfs.attributes(target))
    end)
    it('keeps the original usable and retries after failed activation',function()
        local before=read(source)
        os.rename=function(a,b) if b==target then return nil,'injected rename failure' end;return rename(a,b) end
        assert.has_error(function() P.open(target,source) end)
        assert.equals(before,read(source));assert.is_nil(lfs.attributes(target))
        os.rename=rename
        assert.equals('fixture-key',P.open(target,source):readSetting('api_key'))
    end)
    it('does not accept stale staging data after a failed write',function()
        local stale=LuaSettings:open(target..'.migrating')
        stale:saveSetting('welite_profile_migrated',1);stale:saveSetting('api_key','stale');stale:flush()
        LuaSettings.flush=function() end
        assert.has_error(function() P.open(target,source) end)
        assert.is_nil(lfs.attributes(target));assert.equals('fixture-key',LuaSettings:open(source):readSetting('api_key'))
        LuaSettings.flush=flush
        assert.equals('fixture-key',P.open(target,source):readSetting('api_key'))
    end)
    it('fails explicitly at the size bound without erasing data',function()
        lfs.attributes=function(path,key)
            if path==source and key=='size' then return P.MAX_BYTES+1 end
            return attributes(path,key)
        end
        assert.has_error(function() P.open(target,source) end)
        assert.is_nil(lfs.attributes(target))
    end)
end)

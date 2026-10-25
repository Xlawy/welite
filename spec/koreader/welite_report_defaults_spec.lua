describe('WeLite default reading reports with native storage and scheduler',function()
    local Storage,Settings,UI,root,old_full,old_settings,settings,report,ledger,clock,document,book
    setup(function()
        require('commonrequire');disable_plugins()
        package.path='plugins/welite.koplugin/?.lua;'..package.path
        Storage=require('datastorage');Settings=require('welite.lib.settings');UI=require('ui/uimanager')
    end)
    before_each(function()
        root=os.tmpname();os.remove(root)
        local lfs=require('libs/libkoreader-lfs');lfs.mkdir(root);lfs.mkdir(root..'/settings')
        old_full,old_settings=Storage.getFullDataDir,Storage.getSettingsDir
        Storage.getFullDataDir=function() return root end
        Storage.getSettingsDir=function() return root..'/settings' end
        settings=Settings:new()
        settings:update_auth({cookies={wr_vid='fixture',wr_skey='fixture'},account={user_vid='fixture'}})
        clock=0;document=nil;book=nil
        ledger=require('welite.lib.reading_time_ledger').open(settings,function() return clock end)
        report=require('welite.lib.read_report'):new{settings=settings,client={},scheduler=UI,time_ledger=ledger,
            get_document=function() return document end,detect_book=function() return book end,
            is_online=function() return true end}
    end)
    after_each(function()
        if report then report:stop('test_cleanup') end
        Storage.getFullDataDir,Storage.getSettingsDir=old_full,old_settings
        require('ffi/util').purgeDir(root)
    end)
    it('starts on opening a book without setup and excludes time spent asleep or on the shelf',function()
        assert.is_false(report:maybe_start('plugin_start'))
        assert.is_nil(report.task)
        document={file=root..'/fixture.epub'};book='book'
        assert.is_true(report:on_reader_ready())
        assert.equals('book',report:status().target_book_id)
        assert.equals('current_document',report:status().target_source)
        assert.equals(30,report:_interval())
        assert.is_function(report.task)
        clock=17;report:on_suspend()
        assert.is_nil(report.task)
        assert.equals(17,ledger:status('fixture','book').pending)
        clock=100;assert.is_true(report:on_resume())
        clock=113;report:on_close_document()
        assert.is_nil(report.task)
        assert.equals(30,ledger:status('fixture','book').pending)
        document=nil;book=nil;clock=150
        assert.is_false(report:maybe_start('shelf'))
        assert.equals(30,ledger:status('fixture','book').pending)
    end)
    it('migrates fixed targets on disk and keeps each open book duration separate',function()
        settings:set('read_report',{enabled=true,mode='manual',book_id='wrong-book',
            book_title='Old fixed target',report_on_open=false,interval_seconds=60})
        settings:flush()
        report.settings=Settings:new()
        local saved=require('luasettings'):open(settings.settings_file):readSetting('read_report')
        assert.same({enabled=true,interval_seconds=60},saved)
        assert.is_false(report:maybe_start('plugin_start'))
        document={file=root..'/a.epub'};book='a'
        assert.is_true(report:on_reader_ready())
        assert.equals(60,report:_interval())
        clock=20;document={file=root..'/b.epub'};book='b'
        assert.is_true(report:on_reader_ready())
        assert.equals('b',report:status().target_book_id)
        clock=35;report:on_close_document()
        assert.equals(20,ledger:status('fixture','a').pending)
        assert.equals(15,ledger:status('fixture','b').pending)
        assert.equals(0,ledger:status('fixture','wrong-book').pending)
        document={file=root..'/local.epub'};book=nil
        local started,_,reason=report:on_reader_ready()
        assert.is_false(started);assert.equals('document_not_weread',reason)
        clock=90;report:on_suspend();clock=120
        assert.is_false(report:on_resume())
        document=nil;clock=150
        assert.is_false(report:maybe_start('shelf'))
        assert.is_nil(report.task);assert.is_nil(ledger.active)
        assert.equals(20,ledger:status('fixture','a').pending)
        assert.equals(15,ledger:status('fixture','b').pending)
    end)
    it('preserves a saved opt-out across reopening and does not start the reader timer',function()
        local config=settings:get('read_report');config.enabled=false
        settings:set('read_report',config);settings:flush()
        assert.is_false(require('luasettings'):open(settings.settings_file):readSetting('read_report').enabled)
        report.settings=Settings:new()
        document={file=root..'/fixture.epub'};book='book'
        local started,_,reason=report:on_reader_ready()
        assert.is_false(started);assert.equals('disabled',reason)
        assert.is_nil(report.task);assert.is_nil(ledger.active)
    end)
end)

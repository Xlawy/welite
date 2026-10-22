describe('original WeLite pixel parity',function()
    local UI,Screen,BB,ffi,Original,Adapter,old_status,new_status
    setup(function()
        require('commonrequire')
        package.path='plugins/welite.koplugin/spec/reference/?.lua;plugins/welite.koplugin/?.lua;'..package.path
        UI=require('ui/uimanager');Screen=require('device').screen;BB=require('ffi/blitbuffer');ffi=require('ffi')
        Original=require('welite/shelf');Adapter=require('welite.ui.welite.shelf_adapter')
        old_status=require('welite/display').status;new_status=require('welite.ui.welite.display').status
        local fixed=function() return {wifi='WIFI已连接',battery='79%',capacity=79,time='13:56'} end
        require('welite/display').status=fixed;require('welite.ui.welite.display').status=fixed
    end)
    teardown(function()
        require('welite/display').status=old_status;require('welite.ui.welite.display').status=new_status
    end)
    it('matches every home pixel at four screen sizes, including badges, cover placeholders and pagination',function()
        local screen_bb,screen_size=Screen.bb,Screen.screen_size
        local actual,expected,a,b
        local ok,err=pcall(function()
            for _,size in ipairs({{600,800},{320,600},{600,400},{1072,1448}}) do
                a=BB.new(size[1],size[2],BB.TYPE_BB8);b=BB.new(size[1],size[2],BB.TYPE_BB8)
                Screen.bb=b;Screen.screen_size={w=size[1],h=size[2]}
                local items,books,paths,cover_paths,downloads={},{},{},{},{}
                local cover='plugins/welite.koplugin/spec/fixtures/cover.png'
                for i=1,8 do
                    local title=i==1 and '很长很长的书名，用于验证中文标题单行截断与居中对齐' or '山间来信 '..i
                    items[i]={kind='book',id=tostring(i),title=title,author='林知远',percent=i==2 and 42 or nil}
                    books[i]={bookId=tostring(i),title=title,author='林知远',progress=items[i].percent,
                        _download_state=i==1 and 'full' or i==2 and 'partial' or nil}
                    if i<=3 then paths['book:'..i]=cover;cover_paths[books[i]]=cover end
                    downloads['book:'..i]=books[i]._download_state
                end
                local overview={monthly={total_seconds=7260}}
                expected=Original:new{items=items,cover_paths=paths,downloads=downloads,overview=overview,actions={},inventory=true}
                actual=Adapter.show({books=books,mode='books',cover_paths=cover_paths,welite_overview=overview,sort_key='default'}, {})
                a:fill(BB.COLOR_WHITE);b:fill(BB.COLOR_WHITE)
                expected:paintTo(a,0,0);actual:paintTo(b,0,0)
                assert.equals(expected.page_size,Adapter.getLayout().page_size)
                local output=os.getenv('WELITE_SCREENSHOT')
                if output then
                    a:writePNG(output:gsub('plugin%-smoke','original-home-'..size[1]..'x'..size[2]))
                    b:writePNG(output:gsub('plugin%-smoke','exact-home-'..size[1]..'x'..size[2]))
                end
                assert.is_true(ffi.string(a.data,a.stride*a.h)==ffi.string(b.data,b.stride*b.h),
                    'home pixels differ at '..size[1]..'x'..size[2])
                expected:free();expected=nil;UI:close(actual);actual=nil
                a:free();a=nil;b:free();b=nil
            end
        end)
        if expected then expected:free() end
        if actual then UI:close(actual) end
        Screen.bb=screen_bb;Screen.screen_size=screen_size
        if a then a:free() end;if b then b:free() end
        assert.is_true(ok,tostring(err))
    end)
    it('matches original filter and both pull-down panel variants pixel for pixel',function()
        local original_panel=require('welite/pulldown')
        local current_panel=require('welite.ui.welite.pulldown')
        local original_filter=require('welite/filter')
        local current_filter=require('welite.ui.welite.filter')
        local controls={snapshot=function() return {wifi='WIFI已连接',wifi_supported=true,wifi_on=true,
            network='家庭网络 ›',time='13:56',battery='79%',capacity=79,light_supported=true,
            light_on=true,brightness=68,night=false} end}
        local host={document={info={number_of_pages=392}},rolling={current_page=128},
            toc={getTocTitleByPage=function() return '第五章' end}}
        local function compare(expected,actual,name)
            local a=BB.new(Screen:getWidth(),Screen:getHeight(),BB.TYPE_BB8)
            local b=BB.new(Screen:getWidth(),Screen:getHeight(),BB.TYPE_BB8)
            a:fill(BB.COLOR_WHITE);b:fill(BB.COLOR_WHITE)
            expected:paintTo(a,0,0);actual:paintTo(b,0,0)
            local equal=ffi.string(a.data,a.stride*a.h)==ffi.string(b.data,b.stride*b.h)
            local output=os.getenv('WELITE_SCREENSHOT')
            if output then a:writePNG(output:gsub('plugin%-smoke','original-'..name));b:writePNG(output:gsub('plugin%-smoke','exact-'..name)) end
            a:free();b:free();expected:free();actual:free()
            assert.is_true(equal,name..' pixels differ')
        end
        for _,reading in ipairs({false,true}) do
            local props={controls=controls,host=reading and host or nil,
                home=function() end,chapters=reading and {catalog=function() end} or nil}
            local old_props,new_props={},{}
            for k,v in pairs(props) do old_props[k]=v;new_props[k]=v end
            compare(original_panel:new(old_props),current_panel:new(new_props),reading and 'reader-panel' or 'home-panel')
        end
        compare(original_filter.new({sort='cloud'},function() end,function() end),
            current_filter.new({sort='cloud'},function() end,function() end),'filter')
    end)
end)

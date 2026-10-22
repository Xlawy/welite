describe('welite collection filtering and sorting',function()
    local C,items
    setup(function() require('commonrequire');package.path='plugins/welite.koplugin/?.lua;'..package.path;C=require('weread.ui.welite.collection') end)
    before_each(function()
        items={{id='b',kind='book',title='Beta',author='',read_updated=10,added=30},
            {id='a',kind='book',title='Alpha',author='',read_updated=20,added=10},
            {id='c',kind='book',title='Charlie',author='Writer'},
            {id='d',kind='book',title='Delta',author='',read_updated=20,added=20}}
    end)
    local function ids(rows) local t={};for _,x in ipairs(rows) do t[#t+1]=x.id end;return t end
    it('sorts all four ways with stable ties and missing dates last',function()
        assert.same({'b','a','c','d'},ids(C.select(items,{}, {},'shelf','cloud')))
        assert.same({'a','d','b','c'},ids(C.select(items,{}, {},'shelf','recent')))
        assert.same({'b','d','a','c'},ids(C.select(items,{}, {},'shelf','added')))
        assert.same({'a','b','c','d'},ids(C.select(items,{}, {},'shelf','title')))
        assert.equals('b',items[1].id)
    end)
    it('includes only published local books and keeps removed cloud books searchable',function()
        local extra={id='z',kind='book',title='Lost',author='Writer'}
        local downloads={['book:a']='partial',['book:z']='full'}
        assert.same({'a','z'},ids(C.select(items,{items[2],extra},downloads,'local','cloud')))
        assert.same({'z'},ids(C.select(items,{extra},downloads,'local','title','writer')))
        assert.same({'b','a','c','d'},ids(C.select(items,{extra},downloads,'shelf','cloud')))
        assert.same({},C.select(items,{extra},{},'local','cloud'))
    end)
    it('combines download filters with categories and search',function()
        local downloads={['book:a']='full',['book:b']='partial'}
        assert.same({'a'},ids(C.select(items,{},downloads,'shelf','cloud','','full')))
        assert.same({'b'},ids(C.select(items,{},downloads,'shelf','cloud','','partial')))
        assert.same({'c','d'},ids(C.select(items,{},downloads,'shelf','cloud','','none')))
        assert.same({},C.select(items,{},downloads,'local','cloud','','none'))
        assert.same({},C.select(items,{},downloads,'shelf','cloud','Beta','full'))
    end)
end)

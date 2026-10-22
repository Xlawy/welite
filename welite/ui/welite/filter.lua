-- A draft form: choices stay local until Apply; Cancel never changes the shelf.
local F={}
function F.new(options,apply,close)
    local Input=require('ui/widget/inputdialog')
    local UI=require('ui/uimanager')
    local draft={sort=options.sort or 'cloud',download=options.download_filter or 'all'}
    local names=require('welite.ui.welite.collection').sorts
    local states={all='全部',full='全书下载',partial='部分下载',none='未下载'}
    local dialog;local rows={};local choices={}
    local function choice(key,group,title)
        local id=group..':'..key
        choices[#choices+1]={id=id,key=key,group=group,title=title}
        return {id=id,text=title,text_font_size=16,text_font_bold=false,preselect=draft[group]==key,
            callback=function()
                draft[group]=key
                for _,c in ipairs(choices) do
                    local b=dialog.button_table:getButtonById(c.id)
                    b.frame.invert=draft[c.group]==c.key
                end
                UI:setDirty(dialog,'ui')
            end}
    end
    rows[#rows+1]={{text='排序',enabled=false,text_font_size=14}}
    rows[#rows+1]={choice('cloud','sort',names.cloud),choice('recent','sort',names.recent)}
    rows[#rows+1]={choice('added','sort',names.added),choice('title','sort',names.title)}
    rows[#rows+1]={{text='下载状态',enabled=false,text_font_size=14}}
    rows[#rows+1]={choice('all','download',states.all),choice('full','download',states.full)}
    local last={choice('partial','download',states.partial)}
    if options.category~='local' then last[#last+1]=choice('none','download',states.none) end
    rows[#rows+1]=last
    rows[#rows+1]={
        {text='重置',id='reset',callback=function()
            draft.sort='cloud';draft.download='all';dialog:setInputText('')
            for _,c in ipairs(choices) do dialog.button_table:getButtonById(c.id).frame.invert=draft[c.group]==c.key end
            UI:setDirty(dialog,'ui')
        end},
        {text='取消',id='close',callback=close},
        {text='应用',id='apply',callback=function() local query=dialog:getInputText();close();apply(query,draft.sort,draft.download) end},
    }
    dialog=Input:new{title='筛选与排序',input=options.query or '',input_hint='搜索书名或作者',keyboard_visible=false,
        width=math.floor(require('device').screen:getWidth()*0.9),buttons=rows}
    return dialog
end
return F

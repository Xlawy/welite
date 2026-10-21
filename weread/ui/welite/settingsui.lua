-- On-demand native dialogs; only one owned window, closed with its host.
local P=require('weread.ui.welite.preferences')
local S={};S.__index=S
function S.new(options)
    options=options or {}
    return setmetatable({ui=options.ui or require('ui/uimanager'),settings=options.settings or G_reader_settings,
        changed=options.changed},S)
end
function S:close()
    if self.dialog then local dialog=self.dialog;self.dialog=nil;self.ui:close(dialog) end
end
function S:showDialog(dialog)
    self:close();self.dialog=dialog;self.ui:show(dialog)
end
function S:save(change)
    P.save(change,self.settings)
    if self.changed then self.changed() end
end
function S:show()
    local value=P.read(self.settings)
    self:showDialog(require('ui/widget/buttondialog'):new{title='WeLite 设置',buttons={
        {{text='时间显示 · '..P.label(value.offset),callback=function() self:timezone() end}},
        {{text='启动 KOReader 时打开 WeLite · '..(value.autostart and '开启' or '关闭'),callback=function()
            self:save{autostart=not value.autostart};self:show()
        end}},
        {{text='关闭',callback=function() self:close() end}},
    }})
end
function S:timezone()
    self:showDialog(require('ui/widget/buttondialog'):new{title='时间显示\n仅影响 WeLite 显示，不修改设备时钟。\n云端阅读统计仍按 UTC+8 自然日计算。',buttons={
        {{text='跟随系统',callback=function() self:save{timezone=true};self:show() end}},
        {{text='手动设置时区',callback=function() self:manual() end}},
        {{text='返回',callback=function() self:show() end}},
    }})
end
function S:manual()
    local offset=P.read(self.settings).offset or 480
    local dialog
    dialog=require('ui/widget/inputdialog'):new{title='固定 UTC 时区（不自动切换夏令时）\n格式 +08:00，范围 -12:00 至 +14:00\n分钟支持 00 / 15 / 30 / 45',
        input=P.label(offset):sub(4),buttons={{
            {text='取消',id='close',callback=function() self:timezone() end},
            {text='保存',callback=function()
                local n=P.parse(dialog:getInputText())
                if n==nil then
                    self.ui:show(require('ui/widget/infomessage'):new{text='时区格式无效，例如 +08:00 或 -03:30。',timeout=3});return
                end
                self:save{timezone=true,offset=n};self:show()
            end},
        }}}
    self:showDialog(dialog);dialog:onShowKeyboard()
end
function S:askStartup(open)
    self:showDialog(require('ui/widget/buttondialog'):new{title='欢迎使用 WeLite\n是否在每次启动 KOReader 时自动打开 WeLite？\n以后可在「WeLite 设置」中修改。',buttons={
        {{text='是，启动时打开 WeLite',callback=function()
            self:save{autostart=true};self:close();open()
        end}},
        {{text='暂不自动打开',callback=function() self:save{autostart=false};self:close() end}},
    }})
end
return S

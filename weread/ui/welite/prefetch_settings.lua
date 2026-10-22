local Panel=require('weread.ui.welite.panel')
local V=require('ui/widget/verticalgroup')
local HS=require('ui/widget/horizontalspan')
local Box=require('ui/widget/textboxwidget')
local Font=require('ui/font')
local UI=require('ui/uimanager')
local Preferences=require('weread.lib.prefetch_preferences')
local View=Panel:extend{}
function View:init() self.heading='章节预下载';Panel.init(self) end
function View:content()
    local cache=self.plugin.settings:get('cache',{})
    local enabled=cache.auto_prefetch_next_chapter==true
    local function text(name,on) return name..' · '..(on and '开启' or '关闭') end
    local function toggle(name,label,on,allowed,set)
        local button=self:button(text(label,on),self.content_width,function()
            set(self.plugin,not on)
            self[1]:free();self[1]=nil;self:init();UI:setDirty(self,'ui')
        end,allowed)
        self[name]=button;self._action_buttons[#self._action_buttons+1]=button
        return button
    end
    return V:new{align='left',HS:new{width=self.content_width},self:space(22),
        Box:new{text='分章阅读时，在后台下载下一章。已缓存章节与全书文件不会重复下载。',
            width=self.content_width,face=Font:getFace('cfont',15)},self:space(22),
        toggle('_chapters_button','自动预下载下一章',enabled,true,Preferences.set_chapters),self:space(16),
        toggle('_annotations_button','预下载划线和想法',self.plugin:isAnnotationPrefetchEnabled(),enabled,Preferences.set_annotations),self:space(16),
        toggle('_notifications_button','显示预下载提示',cache.show_prefetch_notifications~=false,enabled,Preferences.set_notifications),self:space(22),
        Box:new{text='划线和想法预取需先为本书开启批注同步，并会增加网络请求与缓存占用。关闭自动预下载会取消后台章节与批注预取。',
            width=self.content_width,face=Font:getFace('cfont',14)},self:space(18)}
end
function View:onClose()
    if self.closed then return true end
    Panel.onClose(self)
    if self.on_back then self.on_back() end
    return true
end
local M={}
function M.new(plugin,on_back) return View:new{plugin=plugin,on_back=on_back} end
return M

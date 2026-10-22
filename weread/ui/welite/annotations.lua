-- A WeLite entry point for the existing annotation pipeline; no alternate sync state.
local Panel=require('weread.ui.welite.panel')
local UI=require('ui/uimanager')
local V=require('ui/widget/verticalgroup')
local HS=require('ui/widget/horizontalspan')
local Box=require('ui/widget/textboxwidget')
local Font=require('ui/font')
local _=require('weread.lib.i18n').tr
local View=Panel:extend{}
function View:invoke(callback)
    local plugin=self.plugin
    local valid=not self.closed and plugin.ui and plugin.ui.document==self.document
        and plugin.settings:get('account',{}).user_vid==self.account
        and plugin._reader_session_gen==self.generation
    self:onClose()
    if valid then return callback() end
end
function View:content()
    local plugin=self.plugin
    local shown=plugin.settings:get('cache',{}).show_annotations~=false
    local body=V:new{align='left',HS:new{width=self.content_width},self:space(20),
        Box:new{text='同步微信读书的划线和想法，在阅读页显示；点击想法可查看内容。选择章节可限制本次同步范围。',
            width=self.content_width,face=Font:getFace('cfont',15)},self:space(20)}
    local function action(label,callback)
        local button=self:button(label,self.content_width,function() return self:invoke(callback) end)
        self._action_buttons[#self._action_buttons+1]=button
        body[#body+1]=button;body[#body+1]=self:space(14)
        return button
    end
    self._visibility_button=action('阅读页显示 · '..(shown and '开启' or '关闭'),function() return plugin:toggleAnnotationVisibility() end)
    self._management_buttons={}
    for index,item in ipairs(plugin:getUnifiedAnnotationMenuItems()) do
        self._management_buttons[index]=action(item.text_func and item.text_func() or item.text,function()
            return item.callback()
        end)
    end
    body[#body+1]=Box:new{text='隐藏只改变显示；清除会删除本地批注缓存和匹配结果，不删除微信读书云端内容。',
        width=self.content_width,face=Font:getFace('cfont',14)}
    body[#body+1]=self:space(18)
    return body
end
function View:onCloseWidget()
    Panel.onCloseWidget(self)
    if self.plugin.welite_annotations_panel==self then self.plugin.welite_annotations_panel=nil end
end
local M={}
function M.show(plugin)
    if plugin.welite_annotations_panel then return plugin.welite_annotations_panel end
    if not plugin.ui or not plugin.ui.document or not plugin:_xpointerOverlayPrototypeAvailable() then return end
    local view=View:new{heading=_('Underlines and thoughts'),plugin=plugin,document=plugin.ui.document,
        account=plugin.settings:get('account',{}).user_vid,generation=plugin._reader_session_gen}
    plugin.welite_annotations_panel=view
    UI:show(view);return view
end
return M

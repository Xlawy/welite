-- Six tiny local paths, antialiased by KOReader's existing SVG renderer/cache.
-- No new rendering library or font; shared cache is already size-bounded by host.
local Icon=require('ui/widget/iconwidget'):extend{}
local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/weread/ui/welite/[^/]+$')
local names={wifi=true,moon=true,settings=true,refresh=true}
function Icon:init()
    local name=self.kind=='toggle' and (self.on and 'toggle-on' or 'toggle-off') or self.kind
    assert(names[self.kind] or self.kind=='toggle','unknown control icon')
    self.width=math.max(1,math.floor(self.width+0.5));self.height=math.max(1,math.floor(self.height+0.5))
    self.file=root..'/icons/welite/'..name..'.svg'
    self.alpha=true;self.original_in_nightmode=false
end
return Icon

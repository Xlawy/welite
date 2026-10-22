describe('welite fixed-width status clock',function()
    local Clock
    setup(function() require('commonrequire');package.path='plugins/welite.koplugin/?.lua;'..package.path;Clock=require('weread.ui.welite.clock') end)
    it('keeps width and child widgets stable across minute changes',function()
        local clock=Clock:new{text='01:11'};local width=clock:getSize().w
        local hour,minute=clock.hours,clock.minutes
        clock:setText('23:59');assert.equals(width,clock:getSize().w)
        assert.equals(hour,clock.hours);assert.equals(minute,clock.minutes)
        assert.equals('23',clock.hours.text);assert.equals('59',clock.minutes.text)
        clock:setText('00:00');assert.equals(width,clock:getSize().w)
        clock:setText('invalid');assert.equals('--',clock.hours.text);clock:free()
    end)
end)

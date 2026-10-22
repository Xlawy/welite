describe("welite reading data",function()
    local R
    setup(function() require("commonrequire");package.path="plugins/welite.koplugin/?.lua;"..package.path;R=require("weread.ui.welite.reading") end)
    it("expires period caches across calendar boundaries and clock rollback",function()
        local before=os.time{year=2026,month=10,day=31,hour=23,min=59,sec=0}
        local after=before+120
        assert.is_false(R.fresh({updated=before},"monthly",after))
        assert.is_true(R.fresh({updated=before},"annually",after))
        assert.is_false(R.fresh({updated=after},"overall",before))
        assert.is_false(R.fresh({updated=before},"overall",before+3600))
    end)
    it("uses seconds and distinguishes unknown, zero and less than a minute",function()
        assert.equals("1 小时 1 分钟",R.duration(3660))
        assert.equals("不足 1 分钟",R.duration(59));assert.equals("0 分钟",R.duration(0))
        assert.equals("暂无数据",R.duration(nil));assert.equals("暂无数据",R.duration(-1))
    end)
    it("uses authoritative totals instead of bucket sums, and caps rankings",function()
        local data={totalReadTime=120,readTimes={a=9999},readDays=2,readLongest={}}
        for n=1,15 do data.readLongest[n]={book={title="book"},readTime=n} end
        local value=assert(R.summary(data,"monthly"))
        assert.equals(120,value.total_seconds);assert.equals(10,#value.top)
        assert.is_nil(R.summary({readTimes={a=10}},"monthly"))
    end)
    it("keeps one percent as one percent and requires finish time for completion",function()
        local p=R.progress{book={progress=1,recordReadingTime=3600}}
        assert.equals(1,p.percent);assert.equals(3600,p.seconds);assert.is_false(p.finished)
        assert.is_false(R.progress{book={progress=100}}.finished)
        assert.is_true(R.progress{book={progress=100,finishTime=1792425600}}.finished)
    end)
    it("reads today's authoritative bucket without changing the period total",function()
        local day=1792425600
        local summary=assert(R.summary({totalReadTime=8353,readTimes={['1792339200']=8149,['1792425600']=204}},'weekly'))
        summary.updated=day+60
        assert.equals(8353,summary.total_seconds)
        assert.equals(204,R.today({weekly=summary},day+120).total_seconds)
        assert.is_nil(R.today({weekly=summary},day-1))
        assert.is_nil(R.today({weekly=summary},day+86400))
        summary.daily_times[tostring(day)]=0
        assert.equals(0,R.today({weekly=summary},day+120).total_seconds)
        summary.daily_times[tostring(day)]=nil
        assert.is_nil(R.today({weekly=summary},day+120))
    end)
    it("uses the newest daily snapshot, preferring weekly only on equal timestamps",function()
        local day=1792425600
        local overview={monthly={updated=day+10,daily_times={[tostring(day)]=100}},weekly={updated=day+20,daily_times={[tostring(day)]=204}}}
        assert.equals(204,R.today(overview,day+30).total_seconds)
        overview.monthly.updated=day+25
        assert.equals(100,R.today(overview,day+30).total_seconds)
        overview.monthly.daily_times={}
        assert.is_nil(R.today(overview,day+30)) -- a missing new record is not a known zero
    end)
    it("bounds and validates day buckets instead of accepting monthly or malformed keys",function()
        assert.is_nil(R.dailyTimes({bad=1}))
        assert.is_nil(R.dailyTimes({['1792425601']=1}))
        assert.is_nil(R.dailyTimes({['1792425600']=-1}))
        local many={};for i=0,31 do many[tostring(1792425600-i*86400)]=1 end
        assert.is_nil(R.dailyTimes(many))
        assert.is_nil(R.summary({totalReadTime=1,readTimes={['1792425600']=1}},'annually').daily_times)
    end)
    it("invalidates daily-dependent caches at UTC+8 midnight and upgrades old caches",function()
        local day=1792425600
        assert.equals(day,R.dayStart(day+1));assert.equals(day-86400,R.dayStart(day-1))
        for _,mode in ipairs({'weekly','monthly'}) do
            assert.is_false(R.fresh({updated=day-10,daily_times={}},mode,day+10))
            assert.is_false(R.fresh({updated=day+10},mode,day+20))
            assert.is_true(R.fresh({updated=day+10,daily_times={}},mode,day+20))
        end
    end)
end)

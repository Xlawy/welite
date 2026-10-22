-- Bounded home-sync adapter. Reservations and settlements are parent-only;
-- network reporting runs inside the existing shelf worker through ReadReport.
local M={MAX_BOOKS=6,MAX_SECONDS=300}
function M.prepare(report,account)
    local task={report=report,ledger=report and report.time_ledger,account=account,
        batches={},settled={},contexts={},failed=false}
    if not task.ledger then return task end
    local ok,err=pcall(function()
        task.ledger:recover(account)
        for _,book in ipairs(task.ledger:pending_books(account,M.MAX_BOOKS)) do
            local batch,reason=task.ledger:begin_pending(account,book,M.MAX_SECONDS)
            if batch then
                task.batches[#task.batches+1]=batch
                task.contexts[batch.id]={book_id=book,auth_fingerprint=report:_auth_fingerprint(),
                    context_fingerprint=report:_context_fingerprint(book)}
            elseif reason~='reading_time_active' then task.failed=true end
        end
    end)
    if not ok then task.failed=true;task.error=tostring(err) end
    return task
end
function M.run(task,context,publish)
    local receipts={}
    for _,batch in ipairs(task.batches) do
        context.checkCancelled()
        local ok,outcome=pcall(task.report._child_report,task.report,batch.book,
            task.report:_renewal_allowed(),nil,batch.seconds,true)
        receipts[tostring(batch.id)]=ok and outcome or {accepted=false,error_kind='task'}
        publish(receipts)
    end
    return receipts
end
function M.apply(task,receipts,apply_context)
    for _,batch in ipairs(task.batches) do
        local outcome=(receipts or {})[tostring(batch.id)]
        if outcome and not task.settled[batch.id] then
            local result=outcome.accepted and 'accepted'
                or ((outcome.time_report_sent==false or outcome.time_rejected==true) and 'retryable') or 'unknown'
            local ok,err=pcall(task.ledger.settle,task.ledger,batch,result)
            if ok then
                task.settled[batch.id]=true
                if result~='accepted' then task.failed=true end
                if apply_context then
                    local saved=task.contexts[batch.id]
                    -- Auth is merged once by the surrounding shelf worker.
                    local value={book=outcome.book,renew_attempted=outcome.renew_attempted}
                    task.report:_apply_job_outcome(saved,value,true)
                end
            else task.failed=true;task.error=tostring(err) end
        end
    end
end
function M.finish(task,not_started)
    for _,batch in ipairs(task.batches) do
        if not task.settled[batch.id] then
            local ok,err=pcall(task.ledger.settle,task.ledger,batch,not_started and 'retryable' or 'unknown')
            task.failed=true
            if ok then task.settled[batch.id]=true else task.error=tostring(err) end
        end
    end
    if task.ledger then
        local ok,books=pcall(task.ledger.pending_books,task.ledger,task.account,1)
        if not ok or #books>0 then task.failed=true end
        local listed,unresolved=pcall(task.ledger.unresolved,task.ledger,task.account)
        task.uncertain_seconds=0
        if listed then
            for _,entry in ipairs(unresolved) do task.uncertain_seconds=task.uncertain_seconds+entry.seconds end
        end
        if not listed or task.uncertain_seconds>0 then task.failed=true end
    end
    return not task.failed
end
return M

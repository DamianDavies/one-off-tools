/* =====================================================================
   Export-WSRAs-from-HOW.sql
   ---------------------------------------------------------------------
   Pulls every STARTED Worksite Risk Assessment from the HOW forms system
   (MariaDB), via the HOW linked server, over a wide lookback. This is the
   source-of-truth input for the WSRA reconciliation matcher.

   Run in SSMS against the SQL instance that hosts the HOW linked server
   (the same one the Power Automate flow uses, e.g. via HOWdbaccess), then
   save the grid as  wsras.csv  next to Match-WSRAs.ps1.

   "Started" = status <> 'NOT_STARTED' (i.e. IN_PROGRESS or COMPLETE).
   NOTE: started_at in HOW is unreliable (it mirrors the last update and can
   be later than completed_at), so the matcher dates each WSRA by created_at,
   which is stable. Both columns are exported for audit.

   Inner query is MariaDB/MySQL dialect (curdate(), interval, date_sub) and
   all single quotes are doubled for the OPENQUERY string literal.
   ===================================================================== */
select * from openquery(HOW,'
    select  p.code     as Job_Code,
            f.id       as Form_Record_Id,
            f.status   as Form_Status,
            f.created_at,
            f.started_at,
            f.completed_at,
            f1.name    as Form_Name
    from cs_inform_form_record f
        left outer join cs_access_project    p  on f.project_id      = p.id
        inner join      cs_inform_form_version v on f.form_version_id = v.id
        inner join      cs_inform_form         f1 on v.form_id         = f1.id
    where f.deleted = 0
        and f1.name like ''%Worksite Risk Assessment%''
        and f.status <> ''NOT_STARTED''                            -- started (IN_PROGRESS or COMPLETE)
        and f.created_at >= date_sub(curdate(), interval 18 month)  -- 12-month validity + 6-month margin
')

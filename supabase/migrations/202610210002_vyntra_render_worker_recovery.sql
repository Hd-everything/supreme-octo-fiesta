create or replace function public.vyntra_claim_render_job(p_worker_id text)
returns setof public.vyntra_render_jobs
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update public.vyntra_render_jobs
  set status = 'failed',
      error_code = 'worker_lost',
      completed_at = now(),
      updated_at = now()
  where status = 'processing'
    and updated_at < now() - interval '20 minutes'
    and attempts >= 3;

  return query
  with next_job as (
    select id
    from public.vyntra_render_jobs
    where attempts < 3
      and (
        status = 'queued'
        or (status = 'processing' and updated_at < now() - interval '20 minutes')
      )
    order by created_at
    for update skip locked
    limit 1
  )
  update public.vyntra_render_jobs j
  set status = 'processing',
      worker_id = left(p_worker_id, 120),
      started_at = coalesce(j.started_at, now()),
      attempts = j.attempts + 1,
      progress = 0,
      updated_at = now()
  from next_job
  where j.id = next_job.id
  returning j.*;
end;
$$;
revoke all on function public.vyntra_claim_render_job(text) from public, anon, authenticated;
grant execute on function public.vyntra_claim_render_job(text) to service_role;

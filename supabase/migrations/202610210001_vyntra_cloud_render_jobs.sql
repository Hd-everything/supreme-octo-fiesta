create table if not exists public.vyntra_render_jobs (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  project_id text not null check (length(project_id) between 1 and 160),
  idempotency_key text not null check (length(idempotency_key) between 8 and 160),
  project_snapshot jsonb not null check (jsonb_typeof(project_snapshot) = 'object'),
  resolution text not null check (resolution in ('720p','1080p','1440p','2160p','4320p')),
  codec text not null default 'h264' check (codec in ('h264','h265')),
  quality smallint not null default 23 check (quality between 18 and 32),
  status text not null default 'queued' check (status in ('queued','uploading','processing','finalizing','completed','failed','cancel_requested','cancelled')),
  progress smallint not null default 0 check (progress between 0 and 100),
  source_object_paths text[] not null default '{}',
  output_path text,
  output_metadata jsonb,
  error_code text check (error_code is null or length(error_code) <= 100),
  attempts smallint not null default 0 check (attempts between 0 and 10),
  worker_id text,
  created_at timestamptz not null default now(),
  started_at timestamptz,
  completed_at timestamptz,
  updated_at timestamptz not null default now(),
  unique(owner_id, idempotency_key)
);

create index if not exists vyntra_render_jobs_owner_created_idx
  on public.vyntra_render_jobs(owner_id, created_at desc);
create index if not exists vyntra_render_jobs_queue_idx
  on public.vyntra_render_jobs(status, created_at) where status = 'queued';

alter table public.vyntra_render_jobs enable row level security;
revoke all on public.vyntra_render_jobs from anon, authenticated;
grant select on public.vyntra_render_jobs to authenticated;
drop policy if exists "Users can read their own Vyntra render jobs" on public.vyntra_render_jobs;
create policy "Users can read their own Vyntra render jobs"
  on public.vyntra_render_jobs for select to authenticated
  using ((select auth.uid()) = owner_id);

insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values (
  'vyntra-media', 'vyntra-media', false, 1073741824,
  array['video/mp4','video/quicktime','video/x-matroska','audio/mpeg','audio/mp4','image/png','image/jpeg','image/webp']
)
on conflict (id) do nothing;

drop policy if exists "Vyntra users can upload their own media" on storage.objects;
create policy "Vyntra users can upload their own media"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'vyntra-media' and (storage.foldername(name))[1] = (select auth.uid())::text);
drop policy if exists "Vyntra users can read their own media" on storage.objects;
create policy "Vyntra users can read their own media"
  on storage.objects for select to authenticated
  using (bucket_id = 'vyntra-media' and (storage.foldername(name))[1] = (select auth.uid())::text);
drop policy if exists "Vyntra users can update their own media" on storage.objects;
create policy "Vyntra users can update their own media"
  on storage.objects for update to authenticated
  using (bucket_id = 'vyntra-media' and (storage.foldername(name))[1] = (select auth.uid())::text)
  with check (bucket_id = 'vyntra-media' and (storage.foldername(name))[1] = (select auth.uid())::text);
drop policy if exists "Vyntra users can delete their own media" on storage.objects;
create policy "Vyntra users can delete their own media"
  on storage.objects for delete to authenticated
  using (bucket_id = 'vyntra-media' and (storage.foldername(name))[1] = (select auth.uid())::text);

create or replace function public.vyntra_claim_render_job(p_worker_id text)
returns setof public.vyntra_render_jobs
language sql
security definer
set search_path = public, pg_temp
as $$
  with next_job as (
    select id
    from public.vyntra_render_jobs
    where status = 'queued' and attempts < 3
    order by created_at
    for update skip locked
    limit 1
  )
  update public.vyntra_render_jobs j
  set status = 'processing',
      worker_id = left(p_worker_id, 120),
      started_at = coalesce(j.started_at, now()),
      attempts = j.attempts + 1,
      updated_at = now()
  from next_job
  where j.id = next_job.id
  returning j.*;
$$;
revoke all on function public.vyntra_claim_render_job(text) from public, anon, authenticated;
grant execute on function public.vyntra_claim_render_job(text) to service_role;

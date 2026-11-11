-- 在新 Supabase 项目的 SQL Editor 中运行一次。
begin;
create table public.overtime_records (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 work_date date not null,
 start_time time not null,
 end_time time not null,
 overnight boolean not null default false,
 rest_minutes integer not null default 0 check(rest_minutes between 0 and 1439),
 category text not null check(category in ('工作日','休息日','节假日')),
 note text not null default '' check(char_length(note)<=500),
 updated_at timestamptz not null default now(),
 constraint valid_duration check (
  extract(epoch from (end_time-start_time))/60 + case when overnight then 1440 else 0 end - rest_minutes > 0
  and extract(epoch from (end_time-start_time))/60 + case when overnight then 1440 else 0 end - rest_minutes <= 1440
 )
);
create index overtime_user_date on public.overtime_records(user_id,work_date);
alter table public.overtime_records enable row level security;
revoke all on public.overtime_records from anon;
grant select,insert,update,delete on public.overtime_records to authenticated;
create policy own_read on public.overtime_records for select to authenticated using ((select auth.uid())=user_id);
create policy own_insert on public.overtime_records for insert to authenticated with check ((select auth.uid())=user_id);
create policy own_update on public.overtime_records for update to authenticated using ((select auth.uid())=user_id) with check ((select auth.uid())=user_id);
create policy own_delete on public.overtime_records for delete to authenticated using ((select auth.uid())=user_id);
create function public.overtime_touch() returns trigger language plpgsql set search_path = '' as $$
begin new.updated_at=clock_timestamp(); return new; end;
$$;
create trigger overtime_touch before update on public.overtime_records for each row execute function public.overtime_touch();
commit;

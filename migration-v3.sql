-- 先执行 v1 schema.sql、migration-v2.sql、storage.sql，再执行本文件一次。
-- 纠正为个人台账：所有已有真实账号成为各自台账的 root，不再共享记录。
begin;
alter table public.profiles add column owner_id uuid references auth.users(id) on delete cascade;
update public.profiles set owner_id=id,role='root',email=lower(email);
alter table public.profiles alter column owner_id set not null;
create unique index profile_owner_mode on public.profiles(owner_id,role);
create or replace function public.create_profile() returns trigger language plpgsql security definer set search_path='' as $$
begin insert into public.profiles(id,email,role,owner_id) values(new.id,lower(new.email),'root',new.id); return new; end;
$$;
drop function public.set_app_role(uuid,text);
create function public.current_owner() returns uuid language sql stable security definer set search_path='' as $$
 select owner_id from public.profiles where id=(select auth.uid());
$$;
revoke all on function public.current_owner() from public;
grant execute on function public.current_owner() to authenticated;
drop policy profile_read on public.profiles;
create policy profile_read on public.profiles for select to authenticated using(id=auth.uid());
drop policy team_read on public.overtime_records;
drop policy team_insert on public.overtime_records;
drop policy team_update on public.overtime_records;
drop policy team_delete on public.overtime_records;
create policy personal_read on public.overtime_records for select to authenticated using(user_id=public.current_owner());
create policy personal_insert on public.overtime_records for insert to authenticated with check(user_id=public.current_owner() and public.current_app_role() in ('root','editor'));
create policy personal_update on public.overtime_records for update to authenticated using(user_id=public.current_owner() and public.current_app_role() in ('root','editor')) with check(user_id=public.current_owner() and public.current_app_role() in ('root','editor'));
create policy personal_delete on public.overtime_records for delete to authenticated using(user_id=public.current_owner() and public.current_app_role()='root');
drop policy overtime_photo_delete on storage.objects;
create policy overtime_photo_delete on storage.objects for delete to authenticated using(bucket_id='overtime-photos' and public.current_app_role()='root' and exists(select 1 from public.overtime_records r where r.id::text=(storage.foldername(name))[1]));
alter table public.overtime_records add column pay_kind text not null default 'unconfirmed' check(pay_kind in ('unconfirmed','workday','rest','statutory','compensated'));
create table public.payroll_settings (
 owner_id uuid not null references auth.users(id) on delete cascade,
 month date not null check(extract(day from month)=1),
 settings jsonb not null check(jsonb_typeof(settings)='object'),
 updated_at timestamptz not null default now(),
 primary key(owner_id,month)
);
alter table public.payroll_settings enable row level security;
revoke all on public.payroll_settings from anon,authenticated;
grant select,insert,update on public.payroll_settings to authenticated;
create policy payroll_read on public.payroll_settings for select to authenticated using(owner_id=public.current_owner());
create policy payroll_insert on public.payroll_settings for insert to authenticated with check(owner_id=public.current_owner() and public.current_app_role()='root');
create policy payroll_update on public.payroll_settings for update to authenticated using(owner_id=public.current_owner() and public.current_app_role()='root') with check(owner_id=public.current_owner() and public.current_app_role()='root');
create table public.audit_logs (
 id bigint generated always as identity primary key,
 owner_id uuid not null references auth.users(id) on delete cascade,
 actor_id uuid,
 mode text,
 action text not null,
 entity_id text,
 detail jsonb not null default '{}',
 created_at timestamptz not null default now()
);
create index audit_owner_time on public.audit_logs(owner_id,created_at desc,id desc);
alter table public.audit_logs enable row level security;
revoke all on public.audit_logs from anon,authenticated;
grant select on public.audit_logs to authenticated;
create policy root_own_logs on public.audit_logs for select to authenticated using(owner_id=public.current_owner() and public.current_app_role()='root');
create function public.audit_record_change() returns trigger language plpgsql security definer set search_path='' as $$
declare r jsonb; own uuid; eid text;
begin
 r=case when TG_OP='DELETE' then to_jsonb(old) else to_jsonb(new) end;
 own=(r->>case when TG_TABLE_NAME='overtime_records' then 'user_id' else 'owner_id' end)::uuid;
 eid=coalesce(r->>'id',r->>'month');
 insert into public.audit_logs(owner_id,actor_id,mode,action,entity_id,detail)
 values(own,auth.uid(),public.current_app_role(),TG_TABLE_NAME||'.'||lower(TG_OP),eid,
 case when TG_TABLE_NAME='overtime_records' then jsonb_build_object('date',r->>'work_date','start',r->>'start_time','end',r->>'end_time','pay_kind',r->>'pay_kind') else jsonb_build_object('month',r->>'month') end);
 if TG_OP='DELETE' then return old; end if;
 return new;
end;
$$;
create trigger audit_records after insert or update or delete on public.overtime_records for each row execute function public.audit_record_change();
create trigger audit_payroll after insert or update on public.payroll_settings for each row execute function public.audit_record_change();
create function public.audit_photo_change() returns trigger language plpgsql security definer set search_path='' as $$
declare r jsonb; own uuid; rid text;
begin
 r=case when TG_OP='DELETE' then to_jsonb(old) else to_jsonb(new) end;
 if r->>'bucket_id'='overtime-photos' then
 rid=split_part(r->>'name','/',1);
 select user_id into own from public.overtime_records where id::text=rid;
 if own is not null then
 insert into public.audit_logs(owner_id,actor_id,mode,action,entity_id,detail) values(own,auth.uid(),public.current_app_role(),'photo.'||lower(TG_OP),rid,jsonb_build_object('file',r->>'name'));
 end if;
 end if;
 if TG_OP='DELETE' then return old; end if; return new;
end;
$$;
create trigger audit_overtime_photos after insert or delete on storage.objects for each row execute function public.audit_photo_change();
create function public.audit_password_change() returns trigger language plpgsql security definer set search_path='' as $$
declare p public.profiles;
begin
 select * into p from public.profiles where id=new.id;
 if found then
 insert into public.audit_logs(owner_id,actor_id,mode,action,entity_id) values(p.owner_id,auth.uid(),p.role,'auth.password_changed',p.role);
 end if;
 return new;
end;
$$;
create trigger audit_password after update of encrypted_password on auth.users for each row when(old.encrypted_password is distinct from new.encrypted_password) execute function public.audit_password_change();
commit;

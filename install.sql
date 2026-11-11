-- 新项目一次性初始化 v4，整体事务；已有 v3 仅运行 migration-v4.sql。
begin;
-- 在新 Supabase 项目的 SQL Editor 中运行一次。

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

-- 已运行 schema.sql 的项目再执行本文件一次。共享台账模式。

create table public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 email text not null,
 role text not null default 'viewer' check(role in ('root','editor','viewer'))
);
alter table public.profiles enable row level security;
revoke all on public.profiles from anon,authenticated;
grant select on public.profiles to authenticated;
create function public.current_app_role() returns text language sql stable security definer set search_path='' as $$
 select role from public.profiles where id=(select auth.uid());
$$;
revoke all on function public.current_app_role() from public;
grant execute on function public.current_app_role() to authenticated;
create policy profile_read on public.profiles for select to authenticated using(id=(select auth.uid()) or public.current_app_role()='root');
create function public.create_profile() returns trigger language plpgsql security definer set search_path='' as $$
begin insert into public.profiles(id,email,role) values(new.id,new.email,'viewer'); return new; end;
$$;
create trigger create_app_profile after insert on auth.users for each row execute function public.create_profile();
insert into public.profiles(id,email) select id,email from auth.users;
create function public.set_app_role(target uuid, new_role text) returns void language plpgsql security definer set search_path='' as $$
begin
 perform pg_advisory_xact_lock(8249001);
 if public.current_app_role() is distinct from 'root' then raise exception '需要 root 权限'; end if;
 if new_role not in ('root','editor','viewer') or new_role is null then raise exception '无效角色'; end if;
 if target=auth.uid() then raise exception '不能更改自己的角色'; end if;
 update public.profiles set role=new_role where id=target;
 if not found then raise exception '账号不存在'; end if;
end;
$$;
revoke all on function public.set_app_role(uuid,text) from public;
grant execute on function public.set_app_role(uuid,text) to authenticated;
drop policy own_read on public.overtime_records;
drop policy own_insert on public.overtime_records;
drop policy own_update on public.overtime_records;
drop policy own_delete on public.overtime_records;
create policy team_read on public.overtime_records for select to authenticated using(public.current_app_role() in ('root','editor','viewer'));
create policy team_insert on public.overtime_records for insert to authenticated with check(public.current_app_role() in ('root','editor') and user_id=auth.uid());
create policy team_update on public.overtime_records for update to authenticated using(public.current_app_role() in ('root','editor')) with check(public.current_app_role() in ('root','editor'));
create policy team_delete on public.overtime_records for delete to authenticated using(public.current_app_role()='root');
-- 修改记录时保留原创建人。
create or replace function public.overtime_touch() returns trigger language plpgsql set search_path='' as $$
begin
 if new.user_id is distinct from old.user_id then raise exception '不能更改创建人'; end if;
 new.updated_at=clock_timestamp(); return new;
end;
$$;

-- 在 Authentication 创建第一个账号后，单独执行下面语句，替换真实邮箱：
-- update public.profiles set role='root' where email='你的邮箱';

-- 执行 schema.sql 和 migration-v2.sql 后执行一次。

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('overtime-photos','overtime-photos',false,5242880,array['image/jpeg','image/png','image/webp']);
create policy overtime_photo_read on storage.objects for select to authenticated using (
 bucket_id='overtime-photos' and public.current_app_role() in ('root','editor','viewer')
 and exists(select 1 from public.overtime_records r where r.id::text=(storage.foldername(name))[1])
);
create policy overtime_photo_insert on storage.objects for insert to authenticated with check (
 bucket_id='overtime-photos' and public.current_app_role() in ('root','editor')
 and array_length(storage.foldername(name),1)=1
 and exists(select 1 from public.overtime_records r where r.id::text=(storage.foldername(name))[1])
);
create policy overtime_photo_delete on storage.objects for delete to authenticated using (
 bucket_id='overtime-photos' and public.current_app_role()='root'
);

-- 先执行 v1 schema.sql、migration-v2.sql、storage.sql，再执行本文件一次。
-- 纠正为个人台账：所有已有真实账号成为各自台账的 root，不再共享记录。

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

-- 已安装 v3 的项目执行一次。新项目使用最新 install.sql。

update storage.buckets set file_size_limit=20971520 where id='overtime-photos';
create table public.companies (
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 name text not null check(char_length(btrim(name)) between 1 and 80 and name=btrim(name)),
 created_at timestamptz not null default now(),
 unique(id,owner_id),unique(owner_id,name)
);
alter table public.companies enable row level security;
revoke all on public.companies from anon,authenticated;
grant select,insert on public.companies to authenticated;
grant update(name) on public.companies to authenticated;
create policy companies_read on public.companies for select to authenticated using(owner_id=public.current_owner());
create policy companies_insert on public.companies for insert to authenticated with check(owner_id=public.current_owner() and public.current_app_role()='root');
create policy companies_update on public.companies for update to authenticated using(owner_id=public.current_owner() and public.current_app_role()='root') with check(owner_id=public.current_owner() and public.current_app_role()='root');
insert into public.companies(owner_id,name) select distinct owner_id,'默认公司' from public.profiles;
alter table public.overtime_records add column company_id uuid;
update public.overtime_records r set company_id=c.id from public.companies c where c.owner_id=r.user_id and c.name='默认公司';
alter table public.overtime_records alter column company_id set not null;
alter table public.overtime_records add constraint record_company_owner foreign key(company_id,user_id) references public.companies(id,owner_id);
create index records_company_date on public.overtime_records(company_id,work_date);
alter table public.payroll_settings add column company_id uuid;
update public.payroll_settings p set company_id=c.id from public.companies c where c.owner_id=p.owner_id and c.name='默认公司';
alter table public.payroll_settings alter column company_id set not null;
alter table public.payroll_settings drop constraint payroll_settings_pkey;
alter table public.payroll_settings add primary key(owner_id,company_id,month);
alter table public.payroll_settings add constraint payroll_company_owner foreign key(company_id,owner_id) references public.companies(id,owner_id);
alter table public.audit_logs add column company_id uuid;
create or replace function public.audit_record_change() returns trigger language plpgsql security definer set search_path='' as $$
declare r jsonb; own uuid; eid text; cid uuid; cname text; previous_company text;
begin
 r=case when TG_OP='DELETE' then to_jsonb(old) else to_jsonb(new) end;
 own=(r->>case when TG_TABLE_NAME='overtime_records' then 'user_id' else 'owner_id' end)::uuid;
 eid=coalesce(r->>'id',r->>'month');cid=(r->>'company_id')::uuid;
 select name into cname from public.companies where id=cid;
 if TG_OP='UPDATE' then previous_company=to_jsonb(old)->>'company_id';end if;
 insert into public.audit_logs(owner_id,actor_id,mode,action,entity_id,company_id,detail)
 values(own,auth.uid(),public.current_app_role(),TG_TABLE_NAME||'.'||lower(TG_OP),eid,cid,
 jsonb_build_object('company',cname,'previous_company_id',previous_company,'date',r->>'work_date','month',r->>'month','start',r->>'start_time','end',r->>'end_time','pay_kind',r->>'pay_kind'));
 if TG_OP='DELETE' then return old; end if;return new;
end;
$$;
create or replace function public.audit_photo_change() returns trigger language plpgsql security definer set search_path='' as $$
declare r jsonb; own uuid; rid text; cid uuid; cname text;
begin
 r=case when TG_OP='DELETE' then to_jsonb(old) else to_jsonb(new) end;
 if r->>'bucket_id'='overtime-photos' then
 rid=split_part(r->>'name','/',1);
 select user_id,company_id into own,cid from public.overtime_records where id::text=rid;
 select name into cname from public.companies where id=cid;
 if own is not null then insert into public.audit_logs(owner_id,actor_id,mode,action,entity_id,company_id,detail) values(own,auth.uid(),public.current_app_role(),'photo.'||lower(TG_OP),rid,cid,jsonb_build_object('file',r->>'name','company',cname));end if;
 end if;
 if TG_OP='DELETE' then return old;end if;return new;
end;
$$;
create function public.audit_company_change() returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into public.audit_logs(owner_id,actor_id,mode,action,entity_id,company_id,detail) values(new.owner_id,auth.uid(),public.current_app_role(),'company.'||lower(TG_OP),new.id::text,new.id,jsonb_build_object('company',new.name));
 return new;
end;
$$;
create trigger audit_companies after insert or update on public.companies for each row execute function public.audit_company_change();

commit;

-- 已安装 v3 的项目执行一次。新项目使用最新 install.sql。
begin;
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
-- Explicit backend privileges when automatic table exposure is disabled.
 grant select,update on public.profiles to service_role;
 grant select,insert on public.audit_logs to service_role;
 grant usage,select on sequence public.audit_logs_id_seq to service_role;
commit;


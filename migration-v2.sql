-- 已运行 schema.sql 的项目再执行本文件一次。共享台账模式。
begin;
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
commit;
-- 在 Authentication 创建第一个账号后，单独执行下面语句，替换真实邮箱：
-- update public.profiles set role='root' where email='你的邮箱';

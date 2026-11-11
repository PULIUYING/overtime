-- 执行 schema.sql 和 migration-v2.sql 后执行一次。
begin;
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
commit;

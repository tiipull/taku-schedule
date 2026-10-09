-- Secure RPC migration for taku-schedule.
-- Review before running. Existing table data is preserved.
-- This removes direct anon access to tables; the frontend must call the RPC functions below.

create extension if not exists pgcrypto;

-- Existing policies are intentionally left in place. Direct table privileges are revoked below,
-- so browser clients must use the token-validating RPC functions. This avoids dropping policies.

revoke all on public.schedules, public.participants, public.availability, public.busy_periods, public.notes from anon, authenticated;
grant select, insert, update, delete on public.schedules, public.participants, public.availability, public.busy_periods, public.notes to service_role;

-- RPCs execute with owner privileges and validate share IDs / participant edit tokens.
create or replace function public.create_schedule(
  p_title text, p_start_date date, p_end_date date, p_required_minutes integer
) returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare s public.schedules;
begin
  if length(trim(coalesce(p_title,''))) = 0 or length(p_title) > 200 then
    raise exception '卓名を入力してください（200文字以内）';
  end if;
  if p_start_date is null or p_end_date is null or p_end_date < p_start_date then
    raise exception '日程調整期間が正しくありません';
  end if;
  if p_end_date - p_start_date > 366 then raise exception '期間は366日以内にしてください'; end if;
  if p_required_minutes is null or p_required_minutes < 30 or p_required_minutes > 100000 then
    raise exception '必要プレイ時間が正しくありません';
  end if;
  insert into public.schedules(share_id,title,start_date,end_date,required_minutes)
  values (encode(gen_random_bytes(18),'hex'), trim(p_title), p_start_date, p_end_date, p_required_minutes)
  returning * into s;
  return jsonb_build_object('id',s.id,'share_id',s.share_id,'title',s.title,
    'start_date',s.start_date,'end_date',s.end_date,'required_minutes',s.required_minutes,'created_at',s.created_at);
end $$;

create or replace function public.get_schedule(p_share_id text)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare s public.schedules;
begin
  select * into s from public.schedules where share_id = p_share_id;
  if not found then raise exception '卓が見つかりません'; end if;
  return jsonb_build_object(
    'schedule', jsonb_build_object('id',s.id,'share_id',s.share_id,'title',s.title,
      'start_date',s.start_date,'end_date',s.end_date,'required_minutes',s.required_minutes,'created_at',s.created_at),
    'participants', coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'schedule_id',p.schedule_id,'name',p.name,'color_index',p.color_index,'created_at',p.created_at) order by p.created_at)
      from public.participants p where p.schedule_id=s.id),'[]'::jsonb),
    'availability', coalesce((select jsonb_agg(to_jsonb(a)) from public.availability a join public.participants p on p.id=a.participant_id where p.schedule_id=s.id),'[]'::jsonb),
    'busy_periods', coalesce((select jsonb_agg(to_jsonb(b)) from public.busy_periods b join public.participants p on p.id=b.participant_id where p.schedule_id=s.id),'[]'::jsonb),
    'notes', coalesce((select jsonb_agg(to_jsonb(n)) from public.notes n join public.participants p on p.id=n.participant_id where p.schedule_id=s.id),'[]'::jsonb)
  );
end $$;

create or replace function public.join_schedule(
  p_share_id text, p_name text, p_edit_token text, p_color_index integer
) returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare s public.schedules; p public.participants;
begin
  select * into s from public.schedules where share_id=p_share_id;
  if not found then raise exception '卓が見つかりません'; end if;
  if length(trim(coalesce(p_name,'')))=0 or length(p_name)>80 then raise exception '名前を入力してください（80文字以内）'; end if;
  if length(coalesce(p_edit_token,'')) < 32 then raise exception '編集トークンが不正です'; end if;
  insert into public.participants(schedule_id,name,edit_token,color_index)
  values(s.id,trim(p_name),p_edit_token,greatest(0,least(9,coalesce(p_color_index,0))))
  returning * into p;
  return jsonb_build_object('id',p.id,'schedule_id',p.schedule_id,'name',p.name,'color_index',p.color_index,'created_at',p.created_at);
end $$;

create or replace function public.add_time_entry(
  p_share_id text, p_participant_id uuid, p_edit_token text, p_kind text,
  p_day date, p_start_minute integer, p_end_minute integer
) returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare s public.schedules; new_id uuid; p public.participants;
begin
  select * into p from public.participants where id=p_participant_id and edit_token=p_edit_token;
  if not found then raise exception '編集権限を確認できません'; end if;
  select * into s from public.schedules where id=p.schedule_id and share_id=p_share_id;
  if not found then raise exception '卓が一致しません'; end if;
  if p_day < s.start_date or p_day > s.end_date then raise exception '調整期間外の日付です'; end if;
  if p_start_minute < 0 or p_end_minute > 1620 or p_end_minute <= p_start_minute
     or mod(p_start_minute,30)<>0 or mod(p_end_minute,30)<>0 then
    raise exception '時間は30分単位で指定してください（最大27:00）';
  end if;
  if p_kind='availability' then
    insert into public.availability(participant_id,day,start_minute,end_minute) values(p.id,p_day,p_start_minute,p_end_minute) returning id into new_id;
  elsif p_kind='busy_periods' then
    insert into public.busy_periods(participant_id,day,start_minute,end_minute) values(p.id,p_day,p_start_minute,p_end_minute) returning id into new_id;
  else raise exception '時間種別が不正です'; end if;
  return jsonb_build_object('id',new_id);
end $$;

create or replace function public.add_note(
  p_share_id text, p_participant_id uuid, p_edit_token text, p_day date, p_text text
) returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare s public.schedules; p public.participants; new_id uuid;
begin
  select * into p from public.participants where id=p_participant_id and edit_token=p_edit_token;
  if not found then raise exception '編集権限を確認できません'; end if;
  select * into s from public.schedules where id=p.schedule_id and share_id=p_share_id;
  if not found then raise exception '卓が一致しません'; end if;
  if p_day < s.start_date or p_day > s.end_date then raise exception '調整期間外の日付です'; end if;
  if length(trim(coalesce(p_text,'')))=0 or length(p_text)>2000 then raise exception '自由記載は1〜2000文字で入力してください'; end if;
  insert into public.notes(participant_id,day,text) values(p.id,p_day,trim(p_text)) returning id into new_id;
  return jsonb_build_object('id',new_id);
end $$;

create or replace function public.delete_own_entry(
  p_share_id text, p_participant_id uuid, p_edit_token text, p_kind text, p_entry_id uuid
) returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare p public.participants; s public.schedules; affected integer;
begin
  select * into p from public.participants where id=p_participant_id and edit_token=p_edit_token;
  if not found then raise exception '編集権限を確認できません'; end if;
  select * into s from public.schedules where id=p.schedule_id and share_id=p_share_id;
  if not found then raise exception '卓が一致しません'; end if;
  if p_kind='availability' then delete from public.availability where id=p_entry_id and participant_id=p.id;
  elsif p_kind='busy_periods' then delete from public.busy_periods where id=p_entry_id and participant_id=p.id;
  elsif p_kind='notes' then delete from public.notes where id=p_entry_id and participant_id=p.id;
  else raise exception '削除対象が不正です'; end if;
  get diagnostics affected = row_count;
  if affected=0 then raise exception '自分の登録データが見つかりません'; end if;
  return jsonb_build_object('deleted',true);
end $$;

revoke all on function public.create_schedule(text,date,date,integer) from public;
revoke all on function public.get_schedule(text) from public;
revoke all on function public.join_schedule(text,text,text,integer) from public;
revoke all on function public.add_time_entry(text,uuid,text,text,date,integer,integer) from public;
revoke all on function public.add_note(text,uuid,text,date,text) from public;
revoke all on function public.delete_own_entry(text,uuid,text,text,uuid) from public;

grant execute on function public.create_schedule(text,date,date,integer) to anon, authenticated;
grant execute on function public.get_schedule(text) to anon, authenticated;
grant execute on function public.join_schedule(text,text,text,integer) to anon, authenticated;
grant execute on function public.add_time_entry(text,uuid,text,text,date,integer,integer) to anon, authenticated;
grant execute on function public.add_note(text,uuid,text,date,text) to anon, authenticated;
grant execute on function public.delete_own_entry(text,uuid,text,text,uuid) to anon, authenticated;

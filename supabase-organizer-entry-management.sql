-- Organizer-side participant entry management for taku-schedule.
-- Prepare this file for review; do NOT run it until the schema and deployment are verified.
-- Requires schedules.organizer_token and schedule_exclusions from prior migrations.

create or replace function public.organizer_update_time_entry(
  p_share_id text, p_organizer_token text, p_participant_id uuid,
  p_kind text, p_entry_id uuid, p_day date, p_start_minute integer, p_end_minute integer
) returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare s public.schedules; p public.participants; affected integer;
begin
  select * into s from public.schedules where share_id=p_share_id and organizer_token=p_organizer_token;
  if not found then raise exception '主催者編集URLが無効です'; end if;
  select * into p from public.participants where id=p_participant_id and schedule_id=s.id;
  if not found then raise exception '指定された参加者がこの卓にいません'; end if;
  if p_day is null or p_day<s.start_date or p_day>s.end_date then raise exception '調整期間内の日付を入力してください'; end if;
  if p_start_minute<0 or p_end_minute>1620 or p_end_minute<=p_start_minute
     or mod(p_start_minute,30)<>0 or mod(p_end_minute,30)<>0 then
    raise exception '時刻は30分単位、最大27:00で指定してください';
  end if;
  if p_kind='availability' then
    if exists(select 1 from public.schedule_exclusions e where e.schedule_id=s.id and e.day=p_day
      and p_start_minute<e.end_minute and p_end_minute>e.start_minute) then
      raise exception '主催者が除外した時間が含まれています';
    end if;
    update public.availability set day=p_day,start_minute=p_start_minute,end_minute=p_end_minute
      where id=p_entry_id and participant_id=p.id;
  elsif p_kind='busy_periods' then
    update public.busy_periods set day=p_day,start_minute=p_start_minute,end_minute=p_end_minute
      where id=p_entry_id and participant_id=p.id;
  else raise exception '日程の種類が不正です'; end if;
  get diagnostics affected = row_count;
  if affected=0 then raise exception '対象の入力が見つかりません'; end if;
  return jsonb_build_object('updated',true);
end $$;

create or replace function public.organizer_update_note(
  p_share_id text, p_organizer_token text, p_participant_id uuid,
  p_entry_id uuid, p_day date, p_text text
) returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare s public.schedules; p public.participants; affected integer;
begin
  select * into s from public.schedules where share_id=p_share_id and organizer_token=p_organizer_token;
  if not found then raise exception '主催者編集URLが無効です'; end if;
  select * into p from public.participants where id=p_participant_id and schedule_id=s.id;
  if not found then raise exception '指定された参加者がこの卓にいません'; end if;
  if p_day is null or p_day<s.start_date or p_day>s.end_date then raise exception '調整期間内の日付を入力してください'; end if;
  if length(trim(coalesce(p_text,'')))=0 or length(p_text)>2000 then raise exception 'メモは1〜2000文字で入力してください'; end if;
  update public.notes set day=p_day,text=trim(p_text) where id=p_entry_id and participant_id=p.id;
  get diagnostics affected = row_count;
  if affected=0 then raise exception '対象のメモが見つかりません'; end if;
  return jsonb_build_object('updated',true);
end $$;

create or replace function public.organizer_delete_entry(
  p_share_id text, p_organizer_token text, p_participant_id uuid,
  p_kind text, p_entry_id uuid
) returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare s public.schedules; p public.participants; affected integer;
begin
  select * into s from public.schedules where share_id=p_share_id and organizer_token=p_organizer_token;
  if not found then raise exception '主催者編集URLが無効です'; end if;
  select * into p from public.participants where id=p_participant_id and schedule_id=s.id;
  if not found then raise exception '指定された参加者がこの卓にいません'; end if;
  if p_kind='availability' then delete from public.availability where id=p_entry_id and participant_id=p.id;
  elsif p_kind='busy_periods' then delete from public.busy_periods where id=p_entry_id and participant_id=p.id;
  elsif p_kind='notes' then delete from public.notes where id=p_entry_id and participant_id=p.id;
  else raise exception '削除対象が不正です'; end if;
  get diagnostics affected = row_count;
  if affected=0 then raise exception '対象の入力が見つかりません'; end if;
  return jsonb_build_object('deleted',true);
end $$;

create or replace function public.organizer_clear_all_entries(
  p_share_id text, p_organizer_token text
) returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare s public.schedules; da integer:=0; db integer:=0; dn integer:=0;
begin
  select * into s from public.schedules where share_id=p_share_id and organizer_token=p_organizer_token;
  if not found then raise exception '主催者編集URLが無効です'; end if;
  delete from public.availability a using public.participants p where a.participant_id=p.id and p.schedule_id=s.id;
  get diagnostics da=row_count;
  delete from public.busy_periods b using public.participants p where b.participant_id=p.id and p.schedule_id=s.id;
  get diagnostics db=row_count;
  delete from public.notes n using public.participants p where n.participant_id=p.id and p.schedule_id=s.id;
  get diagnostics dn=row_count;
  return jsonb_build_object('deleted_availability',da,'deleted_busy_periods',db,'deleted_notes',dn);
end $$;

revoke all on function public.organizer_update_time_entry(text,text,uuid,text,uuid,date,integer,integer) from public;
revoke all on function public.organizer_update_note(text,text,uuid,uuid,date,text) from public;
revoke all on function public.organizer_delete_entry(text,text,uuid,text,uuid) from public;
revoke all on function public.organizer_clear_all_entries(text,text) from public;
grant execute on function public.organizer_update_time_entry(text,text,uuid,text,uuid,date,integer,integer) to anon, authenticated;
grant execute on function public.organizer_update_note(text,text,uuid,uuid,date,text) to anon, authenticated;
grant execute on function public.organizer_delete_entry(text,text,uuid,text,uuid) to anon, authenticated;
grant execute on function public.organizer_clear_all_entries(text,text) to anon, authenticated;

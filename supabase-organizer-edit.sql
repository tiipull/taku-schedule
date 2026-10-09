-- Organizer editing and management for taku-schedule.
-- Run this in Supabase SQL Editor after supabase-exclusions.sql.
alter table public.schedules add column if not exists organizer_token text;

create or replace function public.create_schedule_with_exclusions(
  p_title text, p_start_date date, p_end_date date, p_required_minutes integer, p_exclusions jsonb default '[]'::jsonb
) returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare s public.schedules; item jsonb; ex_day date; ex_start integer; ex_end integer; organizer_key text;
begin
  if length(trim(coalesce(p_title,''))) = 0 or length(p_title) > 200 then raise exception '卓名を入力してください（200文字以内）'; end if;
  if p_start_date is null or p_end_date is null or p_end_date < p_start_date then raise exception '日程調整期間が正しくありません'; end if;
  if p_end_date - p_start_date > 366 then raise exception '期間は366日以内にしてください'; end if;
  if p_required_minutes is null or p_required_minutes < 30 or p_required_minutes > 100000 then raise exception '必要プレイ時間が正しくありません'; end if;
  if p_exclusions is null or jsonb_typeof(p_exclusions) <> 'array' then raise exception '除外日の形式が正しくありません'; end if;
  organizer_key := encode(gen_random_bytes(32),'hex');
  insert into public.schedules(share_id,title,start_date,end_date,required_minutes,organizer_token)
  values (encode(gen_random_bytes(18),'hex'), trim(p_title), p_start_date, p_end_date, p_required_minutes, organizer_key)
  returning * into s;
  for item in select value from jsonb_array_elements(p_exclusions) loop
    ex_day := (item->>'day')::date;
    if ex_day < s.start_date or ex_day > s.end_date then raise exception '除外日に期間外の日付があります'; end if;
    insert into public.schedule_exclusions(schedule_id,day,start_minute,end_minute)
    values(s.id,ex_day,0,1620) on conflict do nothing;
  end loop;
  return jsonb_build_object('id',s.id,'share_id',s.share_id,'title',s.title,'start_date',s.start_date,'end_date',s.end_date,'required_minutes',s.required_minutes,'organizer_token',organizer_key);
end $$;

create or replace function public.update_schedule_exclusions(
  p_share_id text, p_organizer_token text, p_title text, p_start_date date, p_end_date date,
  p_required_minutes integer, p_excluded_days jsonb
) returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare s public.schedules; item jsonb; ex_day date;
begin
  select * into s from public.schedules where share_id=p_share_id and organizer_token=p_organizer_token;
  if not found then raise exception '編集用URLが無効です'; end if;
  if length(trim(coalesce(p_title,'')))=0 or length(p_title)>200 then raise exception '卓名を入力してください（200文字以内）'; end if;
  if p_start_date is null or p_end_date is null or p_end_date<p_start_date or p_end_date-p_start_date>366 then raise exception '日程調整期間が正しくありません'; end if;
  if p_required_minutes is null or p_required_minutes<30 or p_required_minutes>100000 then raise exception '必要プレイ時間が正しくありません'; end if;
  if p_excluded_days is null or jsonb_typeof(p_excluded_days)<>'array' then raise exception '除外日の形式が正しくありません'; end if;
  for item in select value from jsonb_array_elements(p_excluded_days) loop
    ex_day := (item->>'day')::date;
    if ex_day<p_start_date or ex_day>p_end_date then raise exception '除外日に期間外の日付があります'; end if;
  end loop;
  update public.schedules set title=trim(p_title),start_date=p_start_date,end_date=p_end_date,required_minutes=p_required_minutes where id=s.id;
  delete from public.schedule_exclusions where schedule_id=s.id;
  for item in select value from jsonb_array_elements(p_excluded_days) loop
    ex_day := (item->>'day')::date;
    insert into public.schedule_exclusions(schedule_id,day,start_minute,end_minute)
    values(s.id,ex_day,0,1620) on conflict do nothing;
  end loop;
  return jsonb_build_object('updated',true);
end $$;

revoke all on function public.create_schedule_with_exclusions(text,date,date,integer,jsonb) from public;
grant execute on function public.create_schedule_with_exclusions(text,date,date,integer,jsonb) to anon, authenticated;
revoke all on function public.update_schedule_exclusions(text,text,text,date,date,integer,jsonb) from public;
grant execute on function public.update_schedule_exclusions(text,text,text,date,date,integer,jsonb) to anon, authenticated;

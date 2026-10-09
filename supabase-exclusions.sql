-- Global schedule exclusions for taku-schedule.
-- Run this file in Supabase SQL Editor after the existing supabase-secure.sql.
create table if not exists public.schedule_exclusions (
  id uuid primary key default gen_random_uuid(),
  schedule_id uuid not null references public.schedules(id) on delete cascade,
  day date not null,
  start_minute integer not null,
  end_minute integer not null,
  created_at timestamptz not null default now(),
  constraint schedule_exclusions_valid_time check (
    start_minute >= 0 and end_minute <= 1620 and end_minute > start_minute
    and mod(start_minute,30)=0 and mod(end_minute,30)=0
  )
);
revoke all on public.schedule_exclusions from anon, authenticated;
grant select, insert, update, delete on public.schedule_exclusions to service_role;

create or replace function public.create_schedule_with_exclusions(
  p_title text, p_start_date date, p_end_date date, p_required_minutes integer, p_exclusions jsonb default '[]'::jsonb
) returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare s public.schedules; item jsonb; ex_day date; ex_start integer; ex_end integer;
begin
  if length(trim(coalesce(p_title,''))) = 0 or length(p_title) > 200 then raise exception '卓名を入力してください（200文字以内）'; end if;
  if p_start_date is null or p_end_date is null or p_end_date < p_start_date then raise exception '日程調整期間が正しくありません'; end if;
  if p_end_date - p_start_date > 366 then raise exception '期間は366日以内にしてください'; end if;
  if p_required_minutes is null or p_required_minutes < 30 or p_required_minutes > 100000 then raise exception '必要プレイ時間が正しくありません'; end if;
  if p_exclusions is null or jsonb_typeof(p_exclusions) <> 'array' then raise exception '除外日時の形式が正しくありません'; end if;
  insert into public.schedules(share_id,title,start_date,end_date,required_minutes)
  values (encode(gen_random_bytes(18),'hex'), trim(p_title), p_start_date, p_end_date, p_required_minutes)
  returning * into s;
  for item in select value from jsonb_array_elements(p_exclusions) loop
    ex_day := (item->>'day')::date;
    ex_start := (item->>'start_minute')::integer;
    ex_end := (item->>'end_minute')::integer;
    if ex_day < s.start_date or ex_day > s.end_date then raise exception '除外日時に期間外の日付があります'; end if;
    if ex_start < 0 or ex_end > 1620 or ex_end <= ex_start or mod(ex_start,30)<>0 or mod(ex_end,30)<>0 then raise exception '除外時間は30分単位で指定してください（最大27:00）'; end if;
    insert into public.schedule_exclusions(schedule_id,day,start_minute,end_minute) values(s.id,ex_day,ex_start,ex_end);
  end loop;
  return jsonb_build_object('id',s.id,'share_id',s.share_id,'title',s.title,'start_date',s.start_date,'end_date',s.end_date,'required_minutes',s.required_minutes,'created_at',s.created_at);
end $$;

create or replace function public.get_schedule(p_share_id text)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare s public.schedules;
begin
  select * into s from public.schedules where share_id = p_share_id;
  if not found then raise exception '卓が見つかりません'; end if;
  return jsonb_build_object(
    'schedule', jsonb_build_object('id',s.id,'share_id',s.share_id,'title',s.title,'start_date',s.start_date,'end_date',s.end_date,'required_minutes',s.required_minutes,'created_at',s.created_at),
    'participants', coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'schedule_id',p.schedule_id,'name',p.name,'color_index',p.color_index,'created_at',p.created_at) order by p.created_at) from public.participants p where p.schedule_id=s.id),'[]'::jsonb),
    'availability', coalesce((select jsonb_agg(to_jsonb(a)) from public.availability a join public.participants p on p.id=a.participant_id where p.schedule_id=s.id),'[]'::jsonb),
    'busy_periods', coalesce((select jsonb_agg(to_jsonb(b)) from public.busy_periods b join public.participants p on p.id=b.participant_id where p.schedule_id=s.id),'[]'::jsonb),
    'notes', coalesce((select jsonb_agg(to_jsonb(n)) from public.notes n join public.participants p on p.id=n.participant_id where p.schedule_id=s.id),'[]'::jsonb),
    'exclusions', coalesce((select jsonb_agg(jsonb_build_object('id',e.id,'day',e.day,'start_minute',e.start_minute,'end_minute',e.end_minute) order by e.day,e.start_minute) from public.schedule_exclusions e where e.schedule_id=s.id),'[]'::jsonb)
  );
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
  if p_start_minute < 0 or p_end_minute > 1620 or p_end_minute <= p_start_minute or mod(p_start_minute,30)<>0 or mod(p_end_minute,30)<>0 then
    raise exception '時間は30分単位で指定してください（最大27:00）';
  end if;
  if p_kind='availability' then
    if exists(select 1 from public.schedule_exclusions e where e.schedule_id=s.id and e.day=p_day and p_start_minute<e.end_minute and p_end_minute>e.start_minute) then
      raise exception '主催者が除外した時間が含まれています';
    end if;
    insert into public.availability(participant_id,day,start_minute,end_minute) values(p.id,p_day,p_start_minute,p_end_minute) returning id into new_id;
  elsif p_kind='busy_periods' then
    insert into public.busy_periods(participant_id,day,start_minute,end_minute) values(p.id,p_day,p_start_minute,p_end_minute) returning id into new_id;
  else raise exception '時間種別が不正です'; end if;
  return jsonb_build_object('id',new_id);
end $$;

revoke all on function public.create_schedule_with_exclusions(text,date,date,integer,jsonb) from public;
grant execute on function public.create_schedule_with_exclusions(text,date,date,integer,jsonb) to anon, authenticated;
revoke all on function public.get_schedule(text) from public;
grant execute on function public.get_schedule(text) to anon, authenticated;
revoke all on function public.add_time_entry(text,uuid,text,text,date,integer,integer) from public;
grant execute on function public.add_time_entry(text,uuid,text,text,date,integer,integer) to anon, authenticated;

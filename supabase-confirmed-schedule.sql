-- Confirmed schedule events for taku-schedule.
-- Additive migration: does not alter or delete existing scheduling data.
-- Apply only after reviewing the current schema and backing up the project.

create table if not exists public.schedule_events (
  id uuid primary key default gen_random_uuid(),
  schedule_id uuid not null references public.schedules(id) on delete cascade,
  title text not null check (length(trim(title)) between 1 and 200),
  event_date date not null,
  start_minute integer not null check (start_minute >= 0 and start_minute < 1620 and mod(start_minute,30)=0),
  end_minute integer not null check (end_minute > 0 and end_minute <= 1620 and mod(end_minute,30)=0),
  details text not null default '' check (length(details) <= 4000),
  target_label text not null default '全員' check (length(target_label) <= 200),
  status text not null default 'confirmed' check (status in ('tentative','confirmed','done','cancelled')),
  created_by uuid not null references public.participants(id),
  updated_by uuid not null references public.participants(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint schedule_events_valid_time check (end_minute > start_minute)
);

create index if not exists schedule_events_schedule_date_idx
  on public.schedule_events(schedule_id, event_date, start_minute);

create table if not exists public.schedule_event_history (
  id bigint generated always as identity primary key,
  event_id uuid not null,
  schedule_id uuid not null references public.schedules(id) on delete cascade,
  actor_participant_id uuid not null references public.participants(id),
  action text not null check (action in ('created','updated','deleted')),
  before_data jsonb,
  after_data jsonb,
  created_at timestamptz not null default now()
);

create index if not exists schedule_event_history_schedule_idx
  on public.schedule_event_history(schedule_id, created_at desc);

revoke all on public.schedule_events, public.schedule_event_history from anon, authenticated;
grant select, insert, update, delete on public.schedule_events, public.schedule_event_history to service_role;

create or replace function public.list_schedule_events(
  p_share_id text, p_participant_id uuid, p_edit_token text
) returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare s public.schedules; p public.participants;
begin
  select * into p from public.participants
   where id=p_participant_id and edit_token=p_edit_token;
  if not found then raise exception '参加者登録が必要です。名前を登録してからご利用ください'; end if;
  select * into s from public.schedules where id=p.schedule_id and share_id=p_share_id;
  if not found then raise exception '卓が一致しません'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',e.id,'title',e.title,'event_date',e.event_date,
      'start_minute',e.start_minute,'end_minute',e.end_minute,
      'details',e.details,'target_label',e.target_label,'status',e.status,
      'created_by',e.created_by,'updated_by',e.updated_by,
      'created_at',e.created_at,'updated_at',e.updated_at,
      'created_by_name',(select name from public.participants where id=e.created_by),
      'updated_by_name',(select name from public.participants where id=e.updated_by)
    ) order by e.event_date,e.start_minute,e.created_at)
    from public.schedule_events e where e.schedule_id=s.id
  ), '[]'::jsonb);
end $$;

create or replace function public.save_schedule_event(
  p_share_id text, p_participant_id uuid, p_edit_token text,
  p_event_id uuid, p_title text, p_event_date date,
  p_start_minute integer, p_end_minute integer,
  p_details text, p_target_label text, p_status text
) returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare s public.schedules; p public.participants; e public.schedule_events; before_json jsonb; action_name text;
begin
  select * into p from public.participants where id=p_participant_id and edit_token=p_edit_token;
  if not found then raise exception '参加者登録が必要です。名前を登録してからご利用ください'; end if;
  select * into s from public.schedules where id=p.schedule_id and share_id=p_share_id;
  if not found then raise exception '卓が一致しません'; end if;
  if p_event_date is null or p_event_date<s.start_date or p_event_date>s.end_date then
    raise exception '卓の調整期間内の日付を指定してください';
  end if;
  if length(trim(coalesce(p_title,'')))=0 or length(p_title)>200 then raise exception '予定名を1〜200文字で入力してください'; end if;
  if length(coalesce(p_details,''))>4000 or length(coalesce(p_target_label,''))>200 then raise exception '詳細または対象の文字数が上限を超えています'; end if;
  if p_start_minute<0 or p_start_minute>=1620 or p_end_minute>1620 or p_end_minute<=p_start_minute
     or mod(p_start_minute,30)<>0 or mod(p_end_minute,30)<>0 then
    raise exception '開始・終了時刻は30分単位、終了は27:00までで指定してください';
  end if;
  if p_status not in ('tentative','confirmed','done','cancelled') then raise exception '予定の状態が不正です'; end if;
  if p_event_id is null then
    insert into public.schedule_events(schedule_id,title,event_date,start_minute,end_minute,details,target_label,status,created_by,updated_by)
    values(s.id,trim(p_title),p_event_date,p_start_minute,p_end_minute,trim(coalesce(p_details,'')),coalesce(nullif(trim(p_target_label),''),'全員'),p_status,p.id,p.id)
    returning * into e;
    action_name := 'created';
  else
    select * into e from public.schedule_events where id=p_event_id and schedule_id=s.id for update;
    if not found then raise exception '編集する予定が見つかりません'; end if;
    before_json := to_jsonb(e);
    update public.schedule_events set title=trim(p_title),event_date=p_event_date,start_minute=p_start_minute,end_minute=p_end_minute,
      details=trim(coalesce(p_details,'')),target_label=coalesce(nullif(trim(p_target_label),''),'全員'),
      status=p_status,updated_by=p.id,updated_at=now()
    where id=e.id returning * into e;
    action_name := 'updated';
  end if;
  insert into public.schedule_event_history(event_id,schedule_id,actor_participant_id,action,before_data,after_data)
  values(e.id,s.id,p.id,action_name,before_json,to_jsonb(e));
  return jsonb_build_object('id',e.id,'action',action_name);
end $$;

create or replace function public.delete_schedule_event(
  p_share_id text, p_participant_id uuid, p_edit_token text, p_event_id uuid
) returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare s public.schedules; p public.participants; e public.schedule_events;
begin
  select * into p from public.participants where id=p_participant_id and edit_token=p_edit_token;
  if not found then raise exception '参加者登録が必要です'; end if;
  select * into s from public.schedules where id=p.schedule_id and share_id=p_share_id;
  if not found then raise exception '卓が一致しません'; end if;
  delete from public.schedule_events where id=p_event_id and schedule_id=s.id returning * into e;
  if not found then raise exception '削除する予定が見つかりません'; end if;
  insert into public.schedule_event_history(event_id,schedule_id,actor_participant_id,action,before_data,after_data)
  values(e.id,s.id,p.id,'deleted',to_jsonb(e),null);
  return jsonb_build_object('deleted',true);
end $$;

revoke all on function public.list_schedule_events(text,uuid,text) from public;
revoke all on function public.save_schedule_event(text,uuid,text,uuid,text,date,integer,integer,text,text,text) from public;
revoke all on function public.delete_schedule_event(text,uuid,text,uuid) from public;
grant execute on function public.list_schedule_events(text,uuid,text) to anon, authenticated;
grant execute on function public.save_schedule_event(text,uuid,text,uuid,text,date,integer,integer,text,text,text) to anon, authenticated;
grant execute on function public.delete_schedule_event(text,uuid,text,uuid) to anon, authenticated;

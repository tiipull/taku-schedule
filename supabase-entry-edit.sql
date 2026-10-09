-- Allow participants to edit only their own entries, validating the same edit token as deletion.
create or replace function public.update_own_entry(
  p_share_id text, p_participant_id uuid, p_edit_token text, p_kind text,
  p_entry_id uuid, p_day date, p_start_minute integer default null,
  p_end_minute integer default null, p_text text default null
) returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare p public.participants; s public.schedules; affected integer;
begin
  select * into p from public.participants where id=p_participant_id and edit_token=p_edit_token;
  if not found then raise exception '編集権限を確認できません'; end if;
  select * into s from public.schedules where id=p.schedule_id and share_id=p_share_id;
  if not found then raise exception '卓が一致しません'; end if;
  if p_day is null or p_day < s.start_date or p_day > s.end_date then raise exception '調整期間外の日付です'; end if;

  if p_kind='availability' or p_kind='busy_periods' then
    if p_start_minute is null or p_end_minute is null or p_start_minute < 0 or p_end_minute > 1620
       or p_end_minute <= p_start_minute or mod(p_start_minute,30)<>0 or mod(p_end_minute,30)<>0 then
      raise exception '時間は30分単位で指定してください（最大27:00）';
    end if;
    if p_kind='availability' and exists(
      select 1 from public.schedule_exclusions e
      where e.schedule_id=s.id and e.day=p_day
        and p_start_minute<e.end_minute and p_end_minute>e.start_minute
    ) then raise exception '主催者が除外した時間が含まれています'; end if;
    if p_kind='availability' then
      update public.availability set day=p_day,start_minute=p_start_minute,end_minute=p_end_minute
      where id=p_entry_id and participant_id=p.id;
    else
      update public.busy_periods set day=p_day,start_minute=p_start_minute,end_minute=p_end_minute
      where id=p_entry_id and participant_id=p.id;
    end if;
  elsif p_kind='notes' then
    if length(trim(coalesce(p_text,'')))=0 or length(p_text)>2000 then raise exception '自由記載は1〜2000文字で入力してください'; end if;
    update public.notes set day=p_day,text=trim(p_text) where id=p_entry_id and participant_id=p.id;
  else raise exception '編集対象が不正です'; end if;
  get diagnostics affected = row_count;
  if affected=0 then raise exception '自分の登録データが見つかりません'; end if;
  return jsonb_build_object('updated',true);
end $$;

revoke all on function public.update_own_entry(text,uuid,text,text,uuid,date,integer,integer,text) from public;
grant execute on function public.update_own_entry(text,uuid,text,text,uuid,date,integer,integer,text) to anon, authenticated;

-- Bulk delete participant entries for taku-schedule.
-- Run this file in the Supabase SQL Editor.
-- Organizer token is required; participant records and schedule settings are preserved.

create or replace function public.organizer_clear_all_entries(
  p_share_id text,
  p_organizer_token text
) returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  s public.schedules;
  deleted_availability integer := 0;
  deleted_busy integer := 0;
  deleted_notes integer := 0;
begin
  select * into s
  from public.schedules
  where share_id = p_share_id
    and organizer_token = p_organizer_token;

  if not found then
    raise exception '主催者編集URLが無効です';
  end if;

  delete from public.availability a
  using public.participants p
  where a.participant_id = p.id
    and p.schedule_id = s.id;
  get diagnostics deleted_availability = row_count;

  delete from public.busy_periods b
  using public.participants p
  where b.participant_id = p.id
    and p.schedule_id = s.id;
  get diagnostics deleted_busy = row_count;

  delete from public.notes n
  using public.participants p
  where n.participant_id = p.id
    and p.schedule_id = s.id;
  get diagnostics deleted_notes = row_count;

  return jsonb_build_object(
    'deleted_availability', deleted_availability,
    'deleted_busy_periods', deleted_busy,
    'deleted_notes', deleted_notes
  );
end;
$$;

revoke all on function public.organizer_clear_all_entries(text, text) from public;
grant execute on function public.organizer_clear_all_entries(text, text) to anon, authenticated;

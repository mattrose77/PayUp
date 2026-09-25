-- PayUp — in-app account deletion (App Store guideline 5.1.1(v)).
--
-- REFERENCE COPY, synced from the live database on 2026-09-24. The function
-- applied to the database is the authority; this
-- file exists so the Swift side's assumptions are written down next to the
-- code that depends on them. Two rules below come from constraints that only
-- exist server-side:
--   * the departing owner's membership row is deleted BEFORE the successor is
--     promoted — a partial unique index allows only one owner per team;
--   * a handover to someone who already owns a team is refused with
--     `successor_owns_team` (display name in the error detail) rather than
--     being left to the entitlement trigger, which would roll the whole
--     transaction back.
--
-- One entry point, one transaction. A sequence of client calls could fail
-- halfway and leave orphaned rows or a team with no owner at all, and the
-- client can guarantee neither ordering nor atomicity.
--
-- Returns which of the four situations applied, so the app can report what
-- actually happened rather than only what it predicted:
--   handed_over   owner left, the remaining admin was promoted
--   team_deleted  sole owner left, the team and its data are gone
--   left_team     admin left, the team is untouched
--   account_only  no team

create or replace function public.delete_account()
returns text
language plpgsql
security definer
set search_path to 'public', 'auth', 'pg_temp'
as $function$
declare
  me uuid := auth.uid();
  owned record;
  successor record;
  outcome text := 'account_only';
begin
  if me is null then
    raise exception 'not_authenticated' using errcode = 'insufficient_privilege';
  end if;

  -- Handle any team this user owns. The app allows one, but loop for safety.
  for owned in
    select t.id, t.name
    from public.teams t
    join public.team_members m on m.team_id = t.id
    where m.user_id = me and m.role = 'owner'
  loop
    select m.id, m.user_id, m.display_name
      into successor
    from public.team_members m
    where m.team_id = owned.id and m.user_id <> me
    order by m.joined_at asc
    limit 1;

    if not found then
      -- Sole owner: destroy the team and everything in it.
      -- fines.player_id is ON DELETE RESTRICT, so fines must go first.
      delete from public.fines where team_id = owned.id;
      delete from public.teams where id = owned.id;
      outcome := 'team_deleted';
    else
      -- Refuse the handover if the successor already owns a team elsewhere.
      if exists (
        select 1
        from public.team_members m
        where m.user_id = successor.user_id
          and m.role = 'owner'
          and m.team_id <> owned.id
      ) then
        raise exception 'successor_owns_team'
          using errcode = 'check_violation',
                detail = successor.display_name;
      end if;

      -- A partial unique index allows only one owner per team, so the
      -- departing owner's row must go before the successor is promoted.
      delete from public.team_members where team_id = owned.id and user_id = me;
      update public.team_members set role = 'owner' where id = successor.id;
      outcome := 'handed_over';
    end if;
  end loop;

  -- Any remaining memberships are admin roles on other people's teams.
  if outcome = 'account_only'
     and exists (select 1 from public.team_members where user_id = me) then
    outcome := 'left_team';
  end if;

  delete from public.team_members where user_id = me;
  -- players.user_id and fines.created_by reference auth.users ON DELETE SET
  -- NULL, so this anonymises any history that stays with a team rather than
  -- being blocked by it. Sessions and identities cascade.
  delete from auth.users where id = me;

  return outcome;
end;
$function$;

revoke all on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;

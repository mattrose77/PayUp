-- PayUp — in-app account deletion (App Store guideline 5.1.1(v)).
--
-- REFERENCE COPY. The function applied to the database is the authority; this
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
set search_path = public, auth, pg_temp
as $$
declare
  me uuid := auth.uid();
  team_ids uuid[];
  current_team uuid;
  my_role text;
  successor uuid;
  successor_user uuid;
  successor_name text;
  outcome text := 'account_only';
begin
  if me is null then
    raise exception 'Not signed in' using errcode = '28000';
  end if;

  -- Collected up front rather than iterated live: the team delete below
  -- cascades into this same table.
  select array_agg(team_id) into team_ids
    from public.team_members
   where user_id = me;

  foreach current_team in array coalesce(team_ids, '{}'::uuid[]) loop
    select role into my_role
      from public.team_members
     where team_id = current_team
       and user_id = me;

    if my_role = 'owner' then
      -- Earliest joined takes over. The app names this person in the
      -- confirmation, so the two have to pick the same way.
      select id, user_id, display_name
        into successor, successor_user, successor_name
        from public.team_members
       where team_id = current_team
         and user_id <> me
       order by joined_at
       limit 1;

      if successor is not null then
        -- Refused up front: the entitlement trigger would otherwise abort the
        -- whole transaction after the account was already half gone.
        if exists (
          select 1 from public.team_members other
           where other.user_id = successor_user
             and other.role = 'owner'
             and other.team_id <> current_team
        ) then
          raise exception 'successor_owns_team'
            using detail = successor_name;
        end if;

        -- Old owner first: a partial unique index allows one owner per team,
        -- so promoting before this delete violates it.
        delete from public.team_members
         where team_id = current_team and user_id = me;

        update public.team_members set role = 'owner' where id = successor;
        if outcome <> 'team_deleted' then
          outcome := 'handed_over';
        end if;
      else
        -- fines.player_id is `on delete restrict`, so the fines have to go
        -- before the cascade from teams reaches players. Everything else
        -- (players, matches, fine_types) follows from the team row.
        delete from public.fines where team_id = current_team;
        delete from public.teams where id = current_team;
        outcome := 'team_deleted';
      end if;
    elsif outcome = 'account_only' then
      outcome := 'left_team';
    end if;
  end loop;

  -- Any membership the cascade didn't already take.
  delete from public.team_members where user_id = me;

  delete from auth.users where id = me;

  return outcome;
end;
$$;

revoke all on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;

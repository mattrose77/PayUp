# PayUp

Matchday fines tracker for a Saturday football team. SwiftUI, iOS 17+, iPhone only.
Data lives in Supabase (auth + Postgres with row-level security); SwiftData is
only used for a small local team cache.

Copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig`, fill in the
Supabase host and publishable key, then open `PayUp.xcodeproj` and run.
`supabase/delete_account.sql` is a reference copy of the account-deletion function.

## Screens

- **Matches** — season pot card (collected vs outstanding, lime bar) over the matchday list.
- **Tally** — the core screen. Pick a fine chip, then tap each player it applies to.
  Chip stays selected, so one fine across six players is six taps. Undo strip along
  the bottom reverses the last dozen actions; long-press a player for their detail
  or to undo their last fine.
- **Player detail** — season total / paid / owes, settle-in-one-tap, full history
  grouped by match with per-fine paid toggles.
- **Fines** — CRUD on fine types. A new team starts with an empty list.
  Long-press to archive (keeps history, drops it from the chip row) or delete.
- **Shame board** — biggest offender, most common fine, cleanest player, full table.
- **Squad** — fast add (type, return, repeat). Players with fines are made
  inactive rather than deleted.
- **Settings** — team (rename, invite code, members), share sign-off, sign out,
  delete account.

## Model notes

- `Fine` snapshots the type's `name` and `amount` at the moment it's issued, so
  re-pricing a fine type later never rewrites what someone already owes.
- Item of the week is a free-text note set per matchday.
- A player with fines can't be deleted (`fines.player_id` is `on delete restrict`);
  deleting a matchday deletes its fines; deleting a fine type keeps issued fines.
- A team has at most two members (owner + admin), and an account owns at most one
  team — both enforced by a Postgres trigger.

## Design

Charcoal `#22211F` ground, beige `#EDE7DA` text and hero cards, one electric green
`#C4F82A` reserved for totals, selected states and the pot bar. Flat — no gradients,
no shadows. Dark only.

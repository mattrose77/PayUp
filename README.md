# PayUp

Matchday fines tracker for a Saturday football team. SwiftUI + SwiftData, iOS 17+.

Open `PayUp.xcodeproj` and run.

## Screens

- **Matches** — season pot card (collected vs outstanding, lime bar) over the matchday list.
- **Tally** — the core screen. Pick a fine chip, then tap each player it applies to.
  Chip stays selected, so one fine across six players is six taps. Undo strip along
  the bottom reverses the last dozen actions; long-press a player for their detail
  or to undo their last fine.
- **Player detail** — season total / paid / owes, settle-in-one-tap, full history
  grouped by match with per-fine paid toggles.
- **Fines** — CRUD on fine types, seeded with the club's twenty defaults.
  Long-press to archive (keeps history, drops it from the chip row) or delete.
- **Shame board** — biggest offender, most common fine, cleanest player, full table.
- **Squad** — fast add (type, return, repeat), shows who's up next for item of the week.

## Model notes

- `Fine` snapshots the type's `name` and `amount` at the moment it's issued, so
  re-pricing a fine type later never rewrites what someone already owes.
- Item of the week auto-rotates: next up is whoever has gone longest without it,
  falling back to squad order. Overridable per match.
- Deleting a player cascades their fines and nullifies any item-of-the-week holds.

## Design

Charcoal `#22211F` ground, beige `#EDE7DA` text and hero cards, one electric green
`#C4F82A` reserved for totals, selected states and the pot bar. Flat — no gradients,
no shadows. Dark only.

# Superseded (2026-10-22)

The standalone `salesman.html` app and the migrations in `supabase/migrations/` on this branch were an
early build. The live system already has the **Aadhaya Team** app (`team.html` in `aadhayahardware/accounts`,
PIN login on `agents`), so the requested features were added there instead:

- Team Hub (tasks / messages from the owner) — `team.html` Kaam tab + `/crm` "Team kaam" section,
  tables `hub_*` (`aadhayahardware/accounts: sql/2026-10-22_team_hub.sql`).
- Visiting card scan → auto-fill — edge function `read-card`.
- City-wise pipeline — `team.html` Dukaan → Naye.

In the database, the objects created from this branch's migrations were switched off, not dropped
(`is_salesman()` returns false, `team_me()` returns nothing, `team_members` marked unused). They can be
dropped later: `team_members, team_posts, team_task_status, team_replies, team_reads, sm_parties, sm_bills`
and the `sm_read` policies on `items, categories, orders, order_lines`.
`place_order()` is unchanged (a repricing change was reverted within minutes; no orders affected).

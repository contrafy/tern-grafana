# Grafana IRM: on-call and incidents

Two blocks and a status segment bring [Grafana IRM](https://grafana.com/docs/grafana-cloud/alerting-and-irm/irm/)
(OnCall and Incident) into Tern:

- **Grafana: On-call** (`tern-grafana.oncall`): open alert groups (firing, acknowledged, silenced; resolved ones on
  request) with state, integration, age, alert count and detail, and every schedule with who is on call now and next.
  Actions: acknowledge, unacknowledge, resolve, unresolve, silence for a chosen duration.
- **Grafana: Incidents** (`tern-grafana.incidents`): open incidents with severity, status and how long they have been
  open, and one incident's detail with roles and timeline. Actions: declare an incident, change its status or
  severity, add a note.
- The status line shows `IRM: 2 alert groups, 1 incident` while something is open, and `you are on call until 22:00`
  first while you are (`irm.user`); clicking it opens On-call.

## Setup

IRM is a Grafana app, so a context needs only its `grafana` endpoint with a service-account token
([configuration.md](configuration.md)). The plugin finds the rest itself:

- `GET /api/plugins/grafana-irm-app/settings` names the OnCall API host (`jsonData.onCallApiUrl`). OnCall requests go
  there with the same token and `X-Grafana-URL: <grafana url>`, as the OnCall API reference prescribes for service
  accounts. The token is only sent to that host over https (plain http only when Grafana itself is plain http).
- The Incident API is called through Grafana's plugin resource proxy,
  `POST <grafana>/api/plugins/grafana-irm-app/resources/api/v1/<Service>.<Method>`, as the Incident API reference
  documents for service-account tokens.

What the service account needs (IRM's roles reference):

| To | Needs |
| --- | --- |
| read schedules, alert groups, names | `grafana-irm-app.schedules:read`, `alert-groups:read`, `user-settings:read`, `integrations:read` (IRM Reader role, or the Viewer basic role) |
| acknowledge, resolve, silence alert groups | `grafana-irm-app.alert-groups:write` (IRM OnCaller or Alert Groups Editor role, or the Editor basic role) |
| read incidents | access to the IRM app (`plugins.app:access` on `grafana-irm-app`) |
| declare and update incidents, add notes | the Editor basic role |

On open, On-call reads Grafana's permission list for the account (`/api/access-control/user/permissions`). Without
`alert-groups:write` it says the block is read-only and refuses to stage an action, naming the permission; a 403 from
any IRM call names the permission or role that call needs.

## Writes are always previewed and confirmed

A key or button only stages an action. The confirmation panel spells out what changes (alert group and its state
before and after, the silence duration and end, the new incident's title and severity, the status or severity change,
the note), what else happens (unacknowledge and unresolve restart escalation and may page people; incident changes run
the stack's incident hooks, which may post to chat or page), and that the action is sent with the context's
service-account token, so IRM records it under the service account (named by its login), not under you. Only `y` or
the Confirm button sends it; `enter` never does, and `n`/`esc` cancels. A failed write is reported with the server's
reason and is never retried. Each decision writes one log line (`tern-grafana irm`) with the block, action, outcome,
context, target id, silence duration and HTTP status only: never titles, notes, labels or credentials. Titles and notes
are not kept in saved state or block args.

## Keys

On-call, alert groups: `j`/`k` move, `enter` detail, `a` acknowledge, `A` unacknowledge, `x` resolve, `X` unresolve,
`s` silence (then left/right or `1`-`6` for 30m, 1h, 2h, 6h, 12h, 24h and `enter`), `o` open in Grafana, `m` show or
hide recently resolved groups, `tab` schedules, `c`/`C` context, `r` refresh. Schedules: `j`/`k`, `tab` back.

Incidents: `j`/`k` move, `enter` detail, `n` declare, `s` status, `v` severity, `o` open in Grafana, `c`/`C` context,
`r` refresh. Detail: `a` add a note, `s`, `v`, `o`, `r`, `esc` back. Declare form: `enter` edits the title, left/right
picks the severity, `D` stages the declaration.

Links: `tern-grafana://oncall?context=<c>&view=groups|schedules&group=<alert group id>` and
`tern-grafana://incidents?context=<c>&id=<incident id>`.

## What is read

- Alert groups: one page of the newest 25 per open state (`state=new|acknowledged|silenced`), with OnCall's total per
  state; the block says when more exist. OnCall's list covers the last 30 days by default. Detail adds the latest
  alerts of the group (`/api/v1/alerts`).
- Schedules: the list, then `current_oncall` and `next_oncall` for the first 12 (reloaded at most every 5 minutes).
- Incidents: `QueryIncidentPreviews` with `isdrill:false -status:resolved` (up to 100), then filtered by the org's
  statuses: custom statuses count by their category, so a stack with an intermediate status (say `RFO`) shows those
  incidents as open. Detail: `GetIncident` and `QueryActivity` (50 newest).
- Statuses come from `StatusService.QueryOrgStatuses`. Severities come from `SeveritiesService.GetOrgSeverities` when
  the stack offers it; IRM 0.128 answers 404 there, so the picker then offers IRM's defaults (Minor, Major, Critical)
  plus the labels in use, and says so.

## Status segment

`irm_poll_host.luau` polls each context in `irm.contexts` every `irm.poll_s` seconds: the IRM discovery (cached for
30 minutes per context and Grafana URL), one-item pages of alert groups per open state for the counts, the open
incidents, and, when `irm.names` is on or `irm.user` is set, the schedules and users. With `irm.user` set it then
reads `current_oncall` of the schedules you are on call in (at most 4) for when your shift ends. It writes kv
`tern-grafana.irm.summary`: per context the counts by state, open incidents by severity, on-call usernames per
schedule, and whether you are on call (schedule names, shift end). No titles, ids or alert content (kv is a 0644
file).

The segment reads `IRM: you are on call until 22:00, <n> alert groups, <m> incidents` (silenced groups are left out:
someone chose to quiet them), red while a group is firing and not acknowledged, amber while groups or incidents are
open, info-toned while you are only on call, and absent while nothing applies or the context has no IRM. A shift ending on
another day names it (`until Tue 20 Oct 00:00`). A part that failed keeps its last value with ` ?`; `IRM ?` when
every poll failed or the poller stopped.

## You

The token belongs to a service account, so IRM has no "you" of its own (OnCall refuses `/users/current` for service
accounts). Set `irm.user` to the email your OnCall user has; it is matched case-insensitively against OnCall users'
emails (`/api/v1/users`, which needs `grafana-irm-app.user-settings:read`, and the first 100 users). Then:

- On-call's header says `you: on call until 22:00`, `you: next on call from Tue 20 Oct 13:00` or `you: not on call`,
  and the schedules view shows you as `you (<username>)`, highlighted. Schedules load with the block for this, on
  either view.
- The status segment starts with `you are on call until <time>` (the latest end among your current shifts).

Attribution is unchanged: actions are still sent with, and recorded under, the service account.

## Testing

Specs (`tests/unit/irm/`) run against responses captured read-only from a Grafana Cloud stack with IRM 0.128.0 and
scrubbed by `scripts/fixtures/scrub_irm.py`: names, emails, ids, titles, messages, label names and values, slugs and
URLs become consistent pseudonyms (the same original maps to the same replacement in every file), phone numbers and
chat identities are dropped, lists are trimmed. The raw captures stay in the gitignored `.sandbox/user/irm-raw/`.
Write answers (`tests/fixtures/irm/docs/`) are the Incident API reference's examples with `error` emptied (the
reference's example text is an error message; success is an empty `error`). Rerun the scrub after a new capture:

```sh
python3 scripts/fixtures/scrub_irm.py   # reads .sandbox/user/irm-raw, writes tests/fixtures/irm/<irm version>
make fixtures test
```

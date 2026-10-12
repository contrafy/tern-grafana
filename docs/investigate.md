# Investigate

Investigate hands what you are looking at to Tern's default agent: an alert, a query or a dashboard panel, with its
labels, queries, time range, a summary of the recent values and links back to Grafana. Nothing is sent until you
have read the prompt and pressed Send.

## Starting an investigation

| Where | Key | What the prompt carries |
| --- | --- | --- |
| Alerts inbox, selected alert (also the **Investigate (i)** button in its detail) | `i` | Name, severity, state and since when, summary, description, value, labels and annotations (Grafana's internal ones hidden), runbook, dashboard and source links; for a Prometheus alert also its query and the recent values of that query |
| Query block | `I` | The expression, the time range and a summary of the values the block shows, and a Grafana Explore link when the context has Grafana |
| Dashboard or panel block, focused panel | `I` | Dashboard title and uid, panel title and type, every query with dashboard variables filled in, the time range, a summary of the panel's values and a link to the panel in Grafana |

The key opens the **Investigate** preview block beside the source. It shows the exact prompt. An alert's preview
first fetches the recent values of the alert's query (`investigate.range`, default the last hour) and adds them to
the prompt; `r` fetches them again.

| Key | Action |
| --- | --- |
| `enter` | Send to a new agent (once; the **Send again** button sends another) |
| `y` | Copy the prompt |
| `r` | Refresh the alert's recent values |
| `q`, `esc` | Close the preview |

Send starts Tern's default agent (`Settings > Agents`) in a new pane, in the working directory of the preview's pane
(Tern gives blocks the directory of the pane they opened from), or your home directory. The prompt asks for a
read-only investigation: the likely cause, the evidence and next steps, without changing anything before asking.
A toast confirms the start or says why the agent could not start.

## How the prompt travels

Tern's halves share only the plugin's kv store and links, and links never carry data. The source block stores a
draft under `tern-grafana.investigate.<id>` and opens `tern-grafana://investigate?id=<id>`; the preview takes the
draft and deletes it. Send stores the final prompt under a new id and opens the same kind of link; the window
deletes that record before it starts the agent. A record is refused once it is older than its lifetime (10 minutes
for a draft, 2 minutes for a send) or already used, so clicking an old link never starts an agent.

The preview keeps the subject (names, labels, queries, value statistics) in its saved state, so a restored preview
shows the same prompt; restoring never sends. kv and saved state are plain files: neither the records nor the
prompt ever contain a credential, a credential source or a header value.

## Configuration

The optional `investigate` section:

```json
"investigate": { "range": "30m" }
```

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `range` | duration string | `"1h"` | How far back an alert's preview fetches the recent values of the alert's query, from `1s` to `7d`. A bad value is reported and the default is used. |

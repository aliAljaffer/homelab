# Umami dashboards

Grafana dashboards over the Umami Postgres database, provisioned from this
directory by the `umami` Argo CD application.

Umami's own boards are stored only in its database, so they cannot be reviewed,
diffed, or restored from Git. These dashboards keep the same queries in Git and
survive a rebuild of the cluster.

## Dashboards

| File                         | Purpose                                                                 |
| ---------------------------- | ----------------------------------------------------------------------- |
| `dashboards/umami-sites.json`| All sites side by side: traffic, bounce, visit length, Core Web Vitals, events. |
| `dashboards/umami-site.json` | One site at a time (`Site` selector): pages, scroll depth, page types, searches, downloads, outbound links, 404s, CWV, audience. |

Both query the `Umami` Grafana datasource, which connects as `grafana_ro`.

## Access control

- `grafana_ro` is a login role with `SELECT` only. It is created by the CNPG
  operator from the `managed.roles` block in `cnpg-cluster.yaml`, and the
  password comes from `umami-grafana-ro.sealed.yaml`.
- `grafana-ro-grants.yaml` runs as an Argo CD PostSync hook. It grants `SELECT`
  on all tables and default privileges, so tables added by an Umami upgrade are
  readable without another change.
- Grafana reaches the database on port 5432. The rule lives in
  `networkpolicy.yaml`, restricted to the Grafana pod.
- The Grafana datasource itself is in
  `kubernetes/infrastructure/monitoring/values.yaml`, and its password is
  `grafana-umami-db.sealed.yaml` in the same directory. The password reaches
  Grafana as an environment variable, so after rotating it run
  `kubectl -n monitoring rollout restart deploy/monitoring-grafana`.

## Changing a dashboard

Edit the JSON file. Argo CD regenerates the ConfigMap (the name gains a hash
suffix), the Grafana sidecar reloads it, and the dashboard updates without a
Grafana restart.

To add a panel:

1. Write SQL against `website_event`, `event_data`, `session`, or `website`.
2. Filter on `$__timeFilter(created_at)` and, in the per-site dashboard, on
   `website_id = ${site:sqlstring}`. Both use the indexes on
   `website_id, created_at`.
3. Use the event names and property keys from `../EVENTS.md`. Do not invent a
   second name for an existing event.
4. Run the query by hand before you commit. Replace the Grafana macros
   (`$__timeFilter`, `$__timeGroup`, `${site:sqlstring}`) with literals:

   ```sh
   kubectl -n umami exec -i umami-db-1 -c postgres -- \
     psql -U postgres -d umami -f - <<'SQL'
   SELECT url_path, count(*) AS pageviews FROM website_event
   WHERE event_type = 1 AND created_at > now() - interval '30 days'
   GROUP BY 1 ORDER BY 2 DESC LIMIT 5;
   SQL
   ```

## Things that break

- The queries read Umami's internal schema. A major Umami upgrade can rename a
  column. The panels show a query error, nothing else changes.
- `event_type` is `1` for pageviews, `2` for custom events, `5` for performance.
- A visit with one pageview counts as a bounce.
- Performance panels need more than two samples per page before a page appears.
- `training-resume.alialjaffer.com` has no traffic yet, so it shows zero rows.

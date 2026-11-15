# Umami event vocabulary and tracking API

The single reference for every site tracked by this Umami instance. It covers
what the tracker exposes, how each project emits events, and the exact event and
property names to use. Update this file before adding or renaming an event on
any site, so the dashboards stay comparable across sites.

## Sites

| Site                 | Website tag | Tracker code                                                |
| -------------------- | ----------- | ----------------------------------------------------------- |
| docs.alialjaffer.com | `docs`      | `docs-system/assets/analytics.js`                            |
| alialjaffer.com      | `portfolio` | `aliAljaffer.github.io/src/app/components/UmamiEvents.tsx`   |
| tuwaiqtracker.com    | `tracker`   | `tuwaiq-tracker/lib/track.ts`                                |

All sites load the tracker from `https://umami.alialjaffer.com` with
`data-performance="true"`, so Core Web Vitals arrive as `performance` events.
The same script is served at `/script.js` and `/assets/web.js`
(`TRACKER_SCRIPT_NAME`).

## Rules

1. Event names use lowercase kebab-case: `page-type`, `file-download`.
2. Property keys are one lowercase word where possible. Do not abbreviate.
3. Every event sends `path` (`location.pathname`). `page-type` and `page-404`
   use the current page path directly. Umami records the page URL on every
   event, but the explicit `path` keeps CSV exports joinable.
4. Free text (`term`, `title`, `alt`) is truncated to 80 characters.
5. Never send names, emails, comment text, or anything else that identifies a
   person.
6. `scheme` is `dark` or `light`, never a label from the page markup.
7. `depth` is one of `25`, `50`, `75`, `100`.
8. Property values are string, number, or boolean. Do not nest objects.
9. A site only implements the events its UI can produce. An event missing from a
   site is expected, not a bug.

## Event API

The tracker exposes three calls on `window.umami`, plus declarative attributes
that need no JavaScript.

| Call                            | Purpose                                                     |
| ------------------------------- | ----------------------------------------------------------- |
| `umami.track(name, data)`       | Send one custom event. `data` is a flat object of properties. |
| `umami.identify(id, data)`      | Attach a stable pseudonymous id to the session. Not used today. |
| `umami.getSession()`            | Read the current session cache and website id. Debugging only. |

Declarative form: put `data-umami-event="event-name"` on the element and
`data-umami-event-<property>="value"` for each property. The tracker handles the
click, sends the event, then follows the link, including modifier keys and
`target="_blank"`. This is available only after the script loads, so it is best
for simple elements that cannot be clicked before hydration.

Script attributes the projects rely on:

| Attribute             | Effect                                                        |
| --------------------- | ------------------------------------------------------------- |
| `data-website-id`     | Required. Selects the website in Umami.                       |
| `data-host-url`       | Sends events to this Umami host instead of the script origin. |
| `data-tag`            | Tags every pageview and performance event with the site name. |
| `data-domains`        | Comma-separated hostnames allowed to send. Stops dev and preview noise. |
| `data-do-not-track`   | Skip the session when the browser sends DNT.                  |
| `data-performance`    | Send TTFB, FCP, LCP, CLS, INP and duration as `performance` events. |
| `data-auto-pageview`  | Set to `false` to send pageviews yourself.                    |
| `data-exclude-search` | Strip the query string from reported URLs.                    |
| `data-exclude-hash`   | Strip the fragment from reported URLs.                        |

The tracker patches `history.pushState` and `history.replaceState`, so a
single-page app gets a pageview about 300 ms after each route change. It also
respects `localStorage["umami.disabled"]` and the `data-domains` list before
sending anything.

### Emit contract

1. Each site wraps `umami.track` in one helper. Components and page scripts call
   the helper, never `window.umami` directly.
2. The helper queues events until the tracker exists, then flushes. A deferred
   or slow tracker must not lose the first page's events. All three sites do
   this today.
3. Send one event per user intent. Track clicks and completed actions, not
   hover, pointer moves, or every keystroke.
4. Derive property values from the DOM or the event at send time. Do not
   hardcode values that the page already shows.
5. If the tracker is blocked by an extension or DNT, the helper becomes a no-op.
   Tracking must never throw into application code.

Wrapper to copy when adding a site or a new bundle entry:

| Site      | Wrapper location                                   | Queue strategy                     |
| --------- | -------------------------------------------------- | ---------------------------------- |
| docs      | local `track` in `assets/analytics.js`             | flush on script load               |
| portfolio | module `track` in `UmamiEvents.tsx`                | flush on any resource load, then on first call |
| tracker   | exported `track` in `lib/track.ts`                 | retry every 500 ms, 20 attempts    |

### Payload examples

```json
{
  "name": "page-type",
  "data": { "type": "episode", "code": "RHC-01", "section": "rhcsa", "lang": "en", "title": "Set up your laptop", "path": "/rhcsa/01-setup/" }
}
```

```json
{
  "name": "search",
  "data": { "term": "kubectl", "length": 7, "lang": "en", "path": "/" }
}
```

```json
{
  "name": "outbound-link",
  "data": { "domain": "github.com", "target": "/aliAljaffer", "path": "/case-study/fai/" }
}
```

## Tracking patterns

These are the patterns already in use. Reuse them before inventing a new one.

| Pattern                | How it works                                                                 | Used by       |
| ---------------------- | ---------------------------------------------------------------------------- | ------------- |
| Page classification    | Read the heading, URL, or a `data-page-type` marker after render, then send `page-type`. | all three     |
| SPA route change       | Re-run page classification when the pathname changes.                        | portfolio     |
| Click delegation       | One document-level click listener classifies the target: deck, file, outbound link, tag, share, image, TOC anchor. | docs, portfolio |
| Scroll milestones      | Track 25, 50, 75, 100 percent once per page. Throttle the scroll handler.     | docs, portfolio |
| Debounced search       | Send `search` after typing pauses or on Enter, with the term and its length.  | all three     |
| Toggle state           | Send the new value, never the old one: `checked`, `active`, `scheme`.        | all three     |
| Download and exit      | Classify by URL: file extensions for downloads, different origin for outbound. | docs, portfolio |
| Theme change           | Observe the theme control or the root class, send `dark` or `light`.          | docs, portfolio |
| Share intent           | Read the share button label, send the network name once.                     | portfolio     |
| Modal or viewer open   | Send the figure description when the viewer opens.                           | portfolio     |
| 404 detection          | Do not trust the path. A static host serves the custom 404 page at the requested URL, so detect the page content or a marker. | all three |
| Completion             | Track the moment a checklist becomes fully checked, once, not every toggle.   | docs          |
| Embed caveat           | Cross-origin iframes (giscus comments) cannot be read. Track the page-level action instead of the iframe. | docs, portfolio |

## Global events

Every site implements these when the UI supports them.

| Event          | Properties              | Meaning                                             |
| -------------- | ----------------------- | --------------------------------------------------- |
| `page-type`    | `type`, `path`, `lang`, `title` | One event per page load or client-side navigation. |
| `page-404`     | `path`, `referrer`      | A not found page was shown.                         |
| `scroll-depth` | `depth`, `path`         | A scroll milestone was reached once per page.       |
| `outbound-link`| `domain`, `target`, `path` | A link left the site.                            |
| `file-download`| `file`, `path`          | A PDF, archive, or installer link was clicked.       |
| `search`       | `term`, `length`, `lang`, `path` | A search was submitted or paused. `lang` optional. |
| `toc-jump`     | `target`, `path`        | An in-page heading link was used.                   |
| `theme-change` | `scheme`, `path`        | The reader switched theme.                          |
| `share`        | `network`, `path`       | A share button was clicked.                         |
| `image-open`   | `alt`, `path`           | A figure was opened in the viewer.                  |
| `rss-click`    | `path`                  | The RSS link was clicked.                           |

## Page types

| Site      | `page-type.type` values                                  |
| --------- | -------------------------------------------------------- |
| docs      | `episode`, `course`, `slide`, `page`, `404`               |
| portfolio | `home`, `case-study`, `tag`, `tags`, `archive`, `page`, `404` |
| tracker   | `courses`, `statistics`, `404`                            |

`page-type` also sends `code` for docs episodes and `section` for the first path
segment on docs.

## Site-specific events

| Event               | Site      | Properties                    | Meaning                                  |
| ------------------- | --------- | ----------------------------- | ---------------------------------------- |
| `course-open`       | tracker   | `code`, `registerable`, `path`| A course card opened on tuwaiq.edu.sa.   |
| `sort`              | tracker   | `value`, `path`               | The course list sort order changed.      |
| `filter`            | tracker   | `value`, `active`, `path`     | A course filter was toggled.             |
| `filter-clear`      | tracker   | `path`                        | All filters were cleared.                |
| `slide-open`        | docs      | `deck`, `path`                | A course slide deck was opened.          |
| `slide-fullscreen`  | docs      | `deck`, `path`                | A slide deck entered fullscreen.         |
| `search-open`       | docs      | `lang`, `path`                | The search dialog was opened.            |
| `tag-filter`        | docs      | `term`, `path`                | A tag started a search.                  |
| `code-copy`         | docs      | `language`, `path`            | A code block was copied.                 |
| `wiki-preview`      | docs      | `term`, `target`, `path`      | A wiki link preview was shown.           |
| `task-toggle`       | docs      | `checked`, `index`, `path`    | A course checklist item was toggled.     |
| `checklist-complete`| docs      | `total`, `path`               | Every checklist item on a page was done. |
| `episode-nav`       | docs      | `direction`, `target`, `path` | Previous or next episode was used.       |
| `diagram-zoom`      | docs      | `action`, `path`              | An architecture diagram was zoomed.      |

## Adding a new site

1. Create the website in Umami and copy its website id.
2. Add the tracker script with `data-website-id`, `data-host-url`,
   `data-tag`, `data-domains`, `data-do-not-track`, and `data-performance`.
3. Add a queueing tracking helper. Copy one of the three implementations above
   instead of writing a fourth.
4. Emit `page-type` on load, and on route change for single-page apps.
5. Handle 404 by page content or a marker, not by URL suffix.
6. Add a row to the Sites table and any new event names to this file.
7. Load a page, then confirm the event appears in Umami within a minute. If it
   does not, check `window.umami`, the network request to `/api/send`, DNT, and
   the `data-domains` list.

## Debugging

- Append `?analytics` on docs to bypass the hostname check. Portfolio and
  tracker do not restrict hostnames, so localhost works there and the events
  carry their site tag.
- `window.umami` missing means the script is blocked or still loading.
- Events are POSTed to `<host-url>/api/send`. A blocked request shows in the
  console and the event is lost, which is expected.
- DNT, `localStorage["umami.disabled"]`, and a hostname outside
  `data-domains` all silence the tracker without errors.

## Umami setup facts

- Deployment: `kubernetes/apps/umami/umami-deployment.yaml`.
- Storage: CloudNativePG cluster in `cnpg-cluster.yaml`.
- Public route: `httproute-umami.yaml`, behind the Gateway tunnel.
- Tracker name: `assets/web.js`, set by `TRACKER_SCRIPT_NAME`.
- Website IDs live in each site's tracker tag, not here.
- Dashboards: `kubernetes/apps/umami/dashboards/`, rendered by Grafana. See
  `kubernetes/apps/umami/README.md`.
- Dashboards: `kubernetes/apps/umami/dashboards/`, rendered in Grafana. See
  `README.md` next to this file.

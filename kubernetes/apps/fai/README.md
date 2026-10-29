# fai

Personal task tracker / Kanban / notetaking app. Source: `github.com/alialjaffer/fai`
(see that repo's `PLAN.md` and `PROGRESS.md` for the full design and build history).

Two containers (backend, frontend) + a dedicated CNPG Postgres cluster, following the
`umami`/`catus-locatus` conventions. Auto-onboarded by the `workloads` ApplicationSet —
no hand-written ArgoCD Application needed. Task/note attachments live on a
`ReadWriteMany` Longhorn PVC (`fai-attachments`, mounted at `/data/attachments`).

## Auth

The backend validates Keycloak-issued JWTs itself (`go-oidc`) against the `fai` public
PKCE client in the `homelab` realm — it does **not** sit behind `oauth2-proxy`. Per
that component's own README: "Apps with their own auth ... generally do not need
this." fai's Go backend qualifies.

> **Operational note**: the `fai` Keycloak client already exists live (created by hand
> in the admin console, since `KeycloakRealmImport` only applies on first realm
> creation and `homelab` already existed). `keycloak-realm-homelab.yaml` documents it
> for a future from-scratch realm recreation, but editing that file alone does not
> affect the live realm.

The docker-compose deployment (same app, same images, alternative to this) uses a
different auth model — SQLite instead of Postgres, oauth2-proxy + Caddy
`forward_auth` instead of direct OIDC validation — see the `fai` repo's own
`docker-compose.prod.yml` and README. The backend's `AUTH_MODE` env var (`oidc` here,
`proxy-header` there) selects between the two; both are implemented and tested, only
the deployment wiring differs.

## Secrets

- `fai-postgres.sealed.yaml` — CNPG bootstrap credentials (`username`/`password`).
- `fai-secret.sealed.yaml` — `DATABASE_URL` (same password as above, a manually
  constructed connection string — CNPG's own bootstrap secret isn't referenced
  directly, matching the `umami` convention), OIDC config, the live Jira
  credentials + default project/status map, the optional AI settings (blank —
  degrades gracefully when unset), the ntfy publisher credentials (shared with
  `kubernetes/infrastructure/ntfy`'s own sealed secret), and the
  `smtp-relay.mail.svc.cluster.local:587` settings used for reminder emails
  (no SMTP credentials — the relay holds the upstream ones), plus `ICS_TOKEN` and
  `PUBLIC_URL` for the read-only calendar feed. It also holds the Telegram
  assistant credentials: `TELEGRAM_BOT_TOKEN`, `TELEGRAM_ALLOWED_USER_ID`, and
  `TELEGRAM_ALLOWED_CHAT_ID`. `TELEGRAM_STATE_FILE` points at
  `/data/attachments/telegram-offset` so the update offset survives restarts on
  the attachments PVC. `ELEVENLABS_API_KEY` (with the `speech_to_text`
  permission) and `ELEVENLABS_STT_MODEL=scribe_v2` enable voice-note
  transcription.

## Calendar feed

`GET /api/calendar.ics?token=<ICS_TOKEN>` is deliberately outside the OIDC middleware:
Apple Calendar cannot complete a browser login. The unguessable token is the
credential, and the authenticated Settings page exposes the full subscription URL.
Rotating `ICS_TOKEN` invalidates existing subscriptions.

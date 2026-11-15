# livesync

CouchDB for [Self-hosted LiveSync](https://github.com/vrtmrz/obsidian-livesync)
at <https://livesync.alialjaffer.com>, reachable by the Obsidian plugin on
desktop and mobile.

Single CouchDB node on a 20Gi Longhorn volume (`couchdb`), configured by
`couchdb-configmap.yaml`:

- `require_valid_user` on both `chttpd` and `chttpd_auth`, so every request
  needs the admin credentials.
- CORS for `app://obsidian.md` (desktop), `capacitor://localhost` (mobile) and
  `http://localhost` (live reload).
- 50MB documents and a 4GB request limit, as recommended by LiveSync.

The admin credentials live in the `couchdb` SealedSecret:

```bash
kubectl -n livesync get secret couchdb \
  -o jsonpath='{.data.COUCHDB_PASSWORD}' | base64 -d
```

The image only reads `COUCHDB_USER` / `COUCHDB_PASSWORD` on first start. Change
the password with the CouchDB API (`_node/_local/_config/admins/ali`), then
reseal the secret, or the next pod start keeps the old one.

## First setup

1. Open <https://livesync.alialjaffer.com/_utils> and log in as `ali`.
2. Create a database (one per vault), for example `obsidian`.
3. In Obsidian, open the LiveSync settings:
   - URI: `https://livesync.alialjaffer.com`
   - Username: `ali`, password from the secret above
   - Database: `obsidian`
4. Turn on End-to-End Encryption in the plugin. The passphrase never reaches
   the server, so note bodies and attachments are encrypted before upload.
5. Repeat step 3 on every other device with the same passphrase.

## Notes

- CouchDB is exposed at the root path. `require_valid_user` answers unauthenticated
  crawlers with 401, and the plugin needs the root path anyway.
- The PVC is covered by Longhorn's `default` recurring backup group.
- One admin user is shared by every vault. LiveSync is the only client; do not
  add public databases to this instance.

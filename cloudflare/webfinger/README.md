# webfinger

WebFinger endpoint on `alialjaffer.com` pointing at the Keycloak issuer. Tailscale
requires it before a tailnet can switch to custom OIDC. Not deployed yet: it only
matters once the tailnet has an `@alialjaffer.com` identity.

```bash
cd cloudflare/webfinger
npx wrangler deploy
curl "https://alialjaffer.com/.well-known/webfinger?resource=acct:ali@alialjaffer.com"
```

The apex is a Next.js site behind Cloudflare, so this is a route-scoped Worker
rather than a static file.

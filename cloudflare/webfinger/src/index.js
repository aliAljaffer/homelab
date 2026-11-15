const ISSUER = "https://kc.alialjaffer.com/realms/homelab";
const REL = "http://openid.net/specs/connect/1.0/issuer";

export default {
  fetch(request) {
    const url = new URL(request.url);
    if (url.pathname !== "/.well-known/webfinger") {
      return new Response("not found", { status: 404 });
    }
    const resource = url.searchParams.get("resource") ?? "";
    if (!resource.startsWith("acct:")) {
      return new Response("resource must be an acct: URI", { status: 400 });
    }
    return Response.json(
      { subject: resource, links: [{ rel: REL, href: ISSUER }] },
      { headers: { "cache-control": "public, max-age=300" } },
    );
  },
};

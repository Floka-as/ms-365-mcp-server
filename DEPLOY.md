# Deploying to m365.mcphub.no

Floka's fork of [softeria/ms-365-mcp-server](https://github.com/softeria/ms-365-mcp-server),
deployed the same way as `gws-mcp` and `fiken-mcp`: a container in Artifact
Registry, manifests in `k8s/`, ArgoCD syncing them from this fork's `main`.

|               |                                                                              |
| ------------- | ---------------------------------------------------------------------------- |
| Host          | `https://m365.mcphub.no`                                                     |
| MCP endpoint  | `https://m365.mcphub.no/mcp` (streamable HTTP)                               |
| Cluster       | `solvr-multitenant-gke`, namespace `mcphub`                                  |
| Image         | `europe-north1-docker.pkg.dev/solvr-multitenant/internal-artifacts/m365-mcp` |
| Tools exposed | mail, calendar, OneDrive/Files, SharePoint — 126 tools                       |
| Auth          | Resource server only — Solvei brokers the Entra authorization-code flow      |

## How auth works here

**Solvei owns the Microsoft OAuth flow; this server only forwards the result.**

Three layers that are easy to run together, so worth separating:

- **Authorization code** is how the token is *obtained*. The user's browser goes
  to Entra, consents, Solvei exchanges the code and stores the refresh token,
  and `ensure_access_token` keeps it fresh inside a 60s margin. This is
  `MCPServer.auth_type = authorization_code`, configured by the customer's org
  admin in Solvei.
- **Bearer** is what is on the wire afterwards. Solvei's
  `MCPServerActiveSerializer.to_representation` rewrites the row to
  `auth_type = bearer` with the resolved access token before the ADK sees it,
  precisely so the ADK needs no new auth path. Every OAuth grant ends this way.
- **Pass-through** is what this server does with it: forwards the bearer to
  Graph unmodified (`src/server.ts:737`). Not `--obo` (which would exchange it
  and need a client secret in the pod), and not the built-in issuer (which would
  make MCP clients run OAuth against `m365.mcphub.no` itself).

In OAuth terms: Entra is the authorization server, Solvei is the client running
the authorization-code grant, this is a pure resource server.

Because the pod neither mints nor stores anything, it holds **no per-customer
configuration at all** — no `MS365_MCP_CLIENT_ID`, `_SECRET` or `_TENANT_ID`,
and no `OnePasswordItem`. The bearer is the entire identity. One pod serves
every tenant, and onboarding customer number two is a Solvei admin form rather
than a deploy.

### What is deliberately not routed

The ingress publishes `/mcp` and nothing else. `/authorize`, `/token` and
`/register` are the built-in Entra proxy, unused here.

`/.well-known` is the one to be careful with. `mcpAuthRouter` builds
protected-resource metadata from `issuerUrl`, so it advertises
`m365.mcphub.no` *itself* as the authorization server. Routed without the three
paths above, a spec-compliant client that is not Solvei would discover an
authorization server whose endpoints 404 — a broken flow rather than a clean
401. `gws-mcp` can route its equivalent because it advertises Google; this
server points at itself. **Route all four together or none.**

Routing all four is the natural next step if `m365.mcphub.no` should become
self-serve for arbitrary MCP clients (Claude Desktop and friends). That needs a
multi-tenant Entra app we own, `--public-url`, and a redirect URI registered
against it.

### The token is not validated here

`/mcp` checks that the bearer is a non-expired JWT and nothing else — no
audience, no tenant, no signature (`src/lib/microsoft-auth.ts:136`). Graph is
the only enforcement point.

This is deliberate, not an oversight. Graph-audience tokens are explicitly not
for third-party validation — Microsoft does not treat their format as
contractual and reserves the right to change it — so a signature check here
would be building on sand, and an unverified `tid` check gates nobody. The
consequence is that the endpoint is usable by anyone holding a valid Microsoft
access token, acting as themselves within their own consented scopes. Nobody can
reach another user's data; Graph sees to that.

If that stops being acceptable, the cheapest fix is a credential mcphub itself
issues, checked at the ingress — which is also what per-customer metering will
need. That requires a small Solvei change, since `authorization_code` rows
collapse to a single `Authorization` header today with no room for a second.

## Onboarding a customer

Everything hard is in the customer's tenant, and none of it touches this repo.

1. **App registration** in their tenant, **Web** platform (Solvei holds a client
   secret), redirect URI copied verbatim from
   `GET /api/v1/mcp-connections/servers/oauth-redirect-uri` — that is the field
   most often typed wrong.
2. **Delegated Graph permissions + admin consent.** `User.Read`, `Mail.Read`,
   `Calendars.Read`, `Sites.Read.All`, `Files.Read.All`, `offline_access` — plus
   `Mail.ReadWrite`, `Mail.Send`, `Calendars.ReadWrite`, `Files.ReadWrite.All`,
   `Sites.ReadWrite.All` if the agent should act rather than only read. The pod
   does not decide this; consent does.
3. **`offline_access` is not optional.** Without a refresh token
   `ensure_access_token` returns `None` and the tools silently vanish from the
   agent an hour after the user connects. Entra issues one whenever
   `offline_access` is in scope, so unlike the Google case
   `extra_authorize_params` stays `{}`.
4. **Solvei MCPServer row**, per org:
   - transport `streamable_http`, url `https://m365.mcphub.no/mcp`
   - auth type `authorization_code`
   - authorize `https://login.microsoftonline.com/{tenant-id}/oauth2/v2.0/authorize`
   - token `https://login.microsoftonline.com/{tenant-id}/oauth2/v2.0/token`
   - the tenant's own id, not `common` — that restricts consent to their org
   - `tool_filter` if this customer should see less than the full 126
5. **Conditional Access.** Solvei's callback is a web app from a datacenter IP.
   Device-compliance or location policies in the customer's tenant will bite
   here, and it is better to find that out in week one.

Consent is **per user** — each member connects from `/settings/profile`. There
is no org-wide flip.

## The tool ceiling

`ENABLED_TOOLS` (in `k8s/configmap.yaml`, generated by `k8s/gen-tool-filter.mjs`)
caps this host at mail, calendar, OneDrive/Files and SharePoint — 126 of the
server's 326 endpoints. Per-customer trimming below that belongs in Solvei's
`tool_filter`, not here, since one pod serves everyone.

`--org-mode` is not optional. Endpoints carrying only `workScopes` and no
personal `scopes` — every SharePoint site, drive and list tool — are dropped
without it (`src/graph-tools.ts:1506`), which would silently remove one of the
three surfaces while everything still looked healthy.

Regenerate after merging upstream, or new endpoints never join the filter:

```sh
make tools && git diff k8s/configmap.yaml
```

## Rate limiting

The server's own per-IP limiter is **off** (`MS365_MCP_RATE_LIMIT_DISABLED`).
Solvei reaches this host over the public internet and back in through the same
cluster's ingress, so every tenant's traffic arrives from one NAT address and
would share a single 120/min bucket — customer A throttling customer B with
nothing in the logs to say so.

The ingress carries a generous global `limit-rps` instead. That is not metering;
it exists so a stranger's runaway loop cannot turn this host into a free Graph
relay.

## One-time setup before the first deploy

1. **DNS/TLS** — nothing by hand. external-dns creates the A record from the
   ingress; cert-manager issues the cert via `letsencrypt-prod`.

2. **ArgoCD repo access** — the per-repo deploy-key arrangement every app here
   uses: an `argocd-m365-mcp (read-only)` deploy key on the GitHub side and a
   `repo-m365-mcp` Secret (labelled
   `argocd.argoproj.io/secret-type=repository`) in `kube-argocd`. Without it the
   Application reports `ComparisonError: ... SSH_AUTH_SOCK not-specified`. To
   rotate: generate a new ed25519 pair, `gh repo deploy-key add`, replace
   `sshPrivateKey` in the Secret.

3. **Bootstrap ArgoCD** (once):

   ```sh
   make deploy      # kubectl apply -f k8s/app.yaml
   ```

## Shipping a change

```sh
make ship        # build, push, bump the image tag, commit
git push         # ArgoCD syncs from main
make status      # what is actually running
make smoke       # 401 without a token; tools/list with MS365_TOKEN set
```

## Merging upstream

```sh
git fetch upstream && git merge upstream/main
make tools       # new endpoints do not join the filter by themselves
make ship && git push
```

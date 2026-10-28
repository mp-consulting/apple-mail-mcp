# Remote access (claude.ai and the Claude apps)

claude.ai, and the Claude apps on iPhone, Android and the desktop, add a remote MCP server as a **custom
connector** and sign in to it with OAuth. Their requests come from Anthropic's servers, so the server must be
reachable at a public HTTPS address. Apple Mail MCP serves this with `apple-mail-mcp remote`, which the menu bar
app runs while **Settings › Remote access** is on; a tunnel (cloudflared, Tailscale Funnel, a reverse proxy)
publishes it.

## Set-up

1. **More settings… › Remote access**: turn on *Let claude.ai and the Claude apps connect*, and enter the
   **public address**: `https://mcp.example.com/me/mail`. The server answers under that path only, so other
   servers can sit beside it on the same host name (`/me/calendar`, `/homeswift`…).
2. **Port** (8590 by default) and **Listen on**: *Every network* when the tunnel runs on another machine (a NAS),
   *This Mac only* when it runs here.
3. **The tunnel route.** With cloudflared, add a public hostname to the tunnel: the host name, the path pattern the
   settings show, and the service `http://<this Mac's address>:8590`. The pattern carries the endpoint, the OAuth
   endpoints under it, and the discovery documents, which RFC 9728 and RFC 8414 put at the root with the path
   appended:

   ```text
   mcp.example.com   path ^/(\.well-known/[^/]+/)?me/mail(/.*)?$   →  http://192.168.1.20:8590
   ```

   Give this Mac a fixed address on the network (a DHCP reservation) when the tunnel runs elsewhere.
4. **A passcode** (8 characters or more) lets you approve a connection from anywhere. Without one, approve it in
   the menu bar app.
5. In claude.ai: **Settings › Connectors › Add custom connector**, the connector URL, no OAuth client ID or secret
   (claude.ai registers itself). **Connect** opens the sign-in page; approve, and claude.ai has the tools. The
   connector shows in the Claude apps signed in to the same account too.

## What the server serves

For the address `https://mcp.example.com/me/mail`:

| Path | What it is |
|---|---|
| `/me/mail` | The MCP endpoint (Streamable HTTP; `POST`, `GET` for the event stream, `DELETE` to end a session). Bearer tokens only. |
| `/.well-known/oauth-protected-resource/me/mail` | RFC 9728 protected resource metadata (also under `/me/mail/.well-known/…`) |
| `/.well-known/oauth-authorization-server/me/mail` | RFC 8414 authorization server metadata (and `openid-configuration`, and under `/me/mail/.well-known/…`) |
| `/me/mail/oauth/register` | RFC 7591 dynamic client registration (public clients, PKCE) |
| `/me/mail/oauth/authorize` | The sign-in page |
| `/me/mail/oauth/token` | Codes and refresh tokens for tokens |
| `/me/mail/oauth/revoke` | RFC 7009 revocation |

A request without a token gets a 401 whose `WWW-Authenticate` names the protected resource metadata, which names
the issuer, `https://mcp.example.com/me/mail`; its metadata lists the endpoints.

## Approving a connection

The sign-in page shows the app's name, where approving sends the browser (claude.ai), and a **Read only** option.

- **Allow** with the passcode. Five wrong passcodes in 15 minutes lock the page until the oldest leaves the window.
- **Approve on my Mac**: the menu bar app shows *Connect to your mail?* with Allow and Deny, as for sending; the
  page waits for the answer.

The buttons wait a moment before they take a click, the page loads nothing from elsewhere, and no other site may
frame it. A client or redirect address the server does not know is shown on the page and never redirected to.

## Tokens and sessions

- Access tokens last an hour; refresh tokens rotate at each use and keep working for 90 days of use. A refresh
  token used again after its replacement (past a minute's grace) ends the grant: someone else has a copy.
- `remote-access.json` in `~/Library/Application Support/apple-mail-mcp` (owner-only, shared with the menu bar app)
  keeps the clients and grants with the SHA-256 of each token, and the passcode's PBKDF2-SHA256 hash.
- Each MCP session has its own toolbox, named after the app in the activity log ("Claude (remote)"), read-only
  when the grant is, and bound to the grant that opened it: another app's token cannot use it.
- **Connected apps › Disconnect** ends a grant; its next request gets a 401 and claude.ai asks to connect again.
- The server answers only for the public host name (and `localhost`), whatever reaches the port.

## Security notes

Remote access puts your mail one approved sign-in away from the internet. What still holds:

- Sending, unsubscribing, rules and big changes wait for your OK in the menu bar app, as for Claude on the Mac
  (Settings › Sending). With the menu bar app not running, nothing is sent.
- A read-only connection gets only the reading tools.
- Reads and writes go through the same server code and limits as the local server: batch limits, path guards,
  Trash only, undo.
- Keep the tunnel's route as narrow as shown, and choose a passcode you use nowhere else.

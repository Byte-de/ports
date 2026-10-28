# Security

Only the latest stable Byte Ports release receives fixes. Please report sensitive
vulnerabilities privately to **kontakt@byte.de** with the affected version,
reproduction steps and expected impact. Do not include private keys, tokens,
project secrets, personal logs or a still-active public preview URL.

For ordinary bugs, use GitHub Issues. Check and redact command lines, project
paths and service logs before sharing them.

Byte Ports controls only processes owned by the logged-in user and revalidates
their identity before sending signals. It never requests root access. Launched
commands receive the user's interactive shell environment, which can hold
credentials; it stays in memory and is passed only to those commands.

A Cloudflare share is intentionally public; possession of the link is sufficient
for access. The app does not add authentication to the shared development
server. It shares only loopback origins (127.0.0.1 or ::1) of a running server
it has just revalidated, and only after one HEAD request over the loopback
interface got an HTTP answer.

Logs redact paths, commands, project names, share links and error descriptions
as `<private>`, and never contain environment values or service output. Still
read a log before attaching it to a report.

Release binaries are Developer ID signed and Apple notarized. The update check,
manual or the optional weekly one, uses the same validation: it accepts only an
HTTPS answer from api.github.com of bounded size, stable version tags and
release URLs from this repository. It never downloads, installs or executes an
update. Cloudflared is pinned by version and SHA-256, with vendor licences
included. See `docs/RELEASING.md` for maintenance.

# Security

Only the latest stable Byte Ports release receives fixes. Please report sensitive
vulnerabilities privately to **kontakt@byte.de** with the affected version,
reproduction steps and expected impact. Do not include private keys, tokens,
project secrets, personal logs or a still-active public preview URL.

For ordinary bugs, use GitHub Issues. Check and redact command lines, project
paths and service logs before sharing them.

Ports controls only processes owned by the logged-in user and revalidates their
identity before sending signals. It never requests root access. A Cloudflare
share is intentionally public; possession of the link is sufficient for access.
The app does not add authentication to the shared development server.

Release binaries are Developer ID signed and Apple notarized. Update checking
accepts only stable version tags and release URLs from this repository. It never
downloads or executes an update automatically. Cloudflared is pinned by version
and SHA-256, with vendor licences included. See `docs/RELEASING.md` for maintenance.

# Security Policy

## Supported versions

Only the latest release of Worldward receives security fixes.

## Reporting a vulnerability

Please **do not** open a public issue for security problems.

Report privately via [GitHub Security Advisories](https://github.com/lakafior/Worldward/security/advisories/new),
or by email to `worldward@smigi.net`.

Please include what you can: affected version and platform, the steps to reproduce,
and what an attacker would gain. You'll get an acknowledgement within a few days,
and credit in the fix's release notes unless you'd rather not be named.

## Scope

Worldward stores travel data locally and, when iCloud sync is enabled, in the user's
own private CloudKit database. The app makes no network calls of its own and has no
backend to attack.

The area most worth your attention is the **optional MCP automation server** on macOS
(*Settings → Automation*), which is off by default. It binds to `127.0.0.1` only,
requires a per-install bearer token compared in constant time, and rejects requests
carrying a non-local `Origin`. Anything that defeats those controls — reaching the
server from off-machine, bypassing or recovering the token, driving write tools while
*Allow Changes* is off — is in scope and worth reporting.

Also in scope: data leaking out of the app's sandbox (App Group, shared snapshots,
exported files, `.wwtrip` imports parsing untrusted input).

Out of scope: anything requiring physical access to an unlocked device, and issues in
Apple's frameworks themselves — please report those to Apple.

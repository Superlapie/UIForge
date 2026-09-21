# Security Policy

UIForge is a local authoring and compilation tool. It reads project assets and writes generated Godot scenes into the workspace; it is not a hostile-code sandbox.

## Reporting a vulnerability

Please report security issues privately through [GitHub Security Advisories](https://github.com/Superlapie/UIForge/security/advisories/new). Do not publish exploitable details in a public issue.

If private reporting is unavailable, open a minimal issue asking for a private contact channel and wait for maintainer guidance before sharing details.

## Scope

Examples include path traversal or arbitrary writes from machine-facing commands, unsafe external dependency resolution, and requests that bypass workspace or output policies.

Treat supplied Godot assets as untrusted input. UIForge is intended to run locally with the user's OS permissions and does not provide a security sandbox.

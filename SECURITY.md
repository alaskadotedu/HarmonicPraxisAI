# Security and contributor setup

## Credentials

Never commit API keys, access tokens, private keys, or machine-bound credential blobs. Configure secrets through environment variables or your deployment platform's secret store. For local development, copy `.env.example` to `.env` and supply your own values; `.env` is ignored by Git.

If a credential was ever committed, treat it as compromised: revoke/rotate it with its issuer immediately. Removing a file in a later commit does not remove it from Git history. Rewriting history can remove old copies but requires coordination and does not replace rotating the credential.

DPAPI-protected files (for example, `*.dpapi`) are bound to a Windows user or machine and must not be used as portable project credentials. Obtain credentials through a supported secret provider instead.

## Cross-platform paths

PowerShell scripts should derive repository-relative paths from `$PSScriptRoot`, not a developer-specific absolute path. Node.js code should resolve paths from `__dirname` or an explicit project root. Do not rely on a particular user profile or drive letter.

The frontend stack launcher uses Windows-oriented facilities such as `HttpListener` and `Start-Process`; use it in a compatible PowerShell environment, and do not assume it runs in a Linux container without a separate cross-platform implementation. Keep runtime prerequisites documented for each entry point.

## Generated files

Runtime databases, logs, CAD exports, and generated telemetry belong in local/output directories and are ignored by default where their names and extensions are covered by `.gitignore`. Curated, reproducible test fixtures should be kept separately (for example, under `data/`) and intentionally tracked.

## Existing repository contents

Ignore rules only prevent untracked files from being added; they do not remove files already tracked or erase their history. Remove exposed secrets, machine-bound blobs, and malformed filenames from the repository with a deletion commit, then assess whether history cleanup is needed. Rotate any credentials before history cleanup.

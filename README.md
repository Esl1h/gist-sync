# gist-sync

Multi-platform gist/snippet synchronizer.

Sync your GitHub gists to multiple destinations: GitLab, Codeberg, Gitea, Forgejo, Bitbucket, and Keybase.

## Why gist-sync?

Keeping code snippets in sync across multiple platforms is tedious. `gist-sync` automates this:

- **Single source of truth** — maintain gists on GitHub, mirror everywhere automatically
- **Platform redundancy** — never lose snippets if a platform goes down
- **Audience reach** — make your code available where your users are
- **Backup strategy** — distributed storage across multiple providers

## Features

- **Multi-target sync** — push to multiple destinations simultaneously
- **TOML configuration** — clean, readable, version-controllable config
- **Advanced filtering** — by visibility, date, name patterns, or specific IDs
- **Conflict handling** — skip, update, or replace existing snippets
- **Description transformation** — add prefixes, suffixes, or custom descriptions
- **Visibility control** — preserve original or force public/private
- **Lifecycle hooks** — run commands before sync, after success, or on failure
- **Dry-run mode** — preview changes without modifying anything
- **Rate limiting** — configurable delays to respect API limits
- **Multiple config locations** — XDG config, script directory, or current directory

## Supported Providers

| Provider   | Role   | API           | Implementation                    |
|------------|--------|---------------|-----------------------------------|
| GitHub     | Source | REST API v3   | Native Gists                      |
| GitLab     | Target | REST API v4   | Snippets                          |
| Codeberg   | Target | Gitea API     | Repositories with `gist-` prefix  |
| Gitea      | Target | Gitea API     | Repositories with `gist-` prefix  |
| Forgejo    | Target | Gitea API     | Repositories with `gist-` prefix  |
| Bitbucket  | Target | REST API 2.0  | Snippets                          |
| Keybase    | Target | CLI + Git     | Private git repositories          |

## Installation

### Dependencies

```bash
# Debian/Ubuntu
sudo apt install curl jq git

# Fedora/RHEL
sudo dnf install curl jq git yq

# Arch Linux
sudo pacman -S curl jq git yq

# macOS
brew install curl jq git yq
```

### TOML Parser

The script requires `yq` (Go version by Mike Farah) or Python `yq` with `tomlq`:

```bash
# Go yq (recommended) - https://github.com/mikefarah/yq
# Already included in most distro repos as 'yq'

# OR Python yq (includes tomlq)
pip install yq
```

### Script Installation

```bash
# Clone repository
git clone https://github.com/Esl1h/gist-sync.git
cd gist-sync

# Or download directly
curl -LO https://raw.githubusercontent.com/Esl1h/gist-sync/main/gist-sync.sh
chmod +x gist-sync.sh

# Optional: install system-wide
sudo install -m 755 gist-sync.sh /usr/local/bin/gist-sync
```

## Configuration

### Quick Start

```bash
# Create config directory
mkdir -p ~/.config/gist-sync

# Copy example configuration
cp config.example.toml ~/.config/gist-sync/config.toml

# Edit with your settings
$EDITOR ~/.config/gist-sync/config.toml
```

### Config File Locations

The script searches for `config.toml` in this order:

1. Path specified via `--config` / `-c` flag
2. `~/.config/gist-sync/config.toml` (XDG standard)
3. Same directory as the script
4. Current working directory

### Configuration Reference

```toml
[general]
cache_dir = "~/.cache/gist-sync"
log_level = "info"          # debug, info, warn, error
log_file = ""               # empty = stdout only
dry_run = false
max_parallel = 5
rate_limit_interval = 1     # seconds between API calls
http_timeout = 30

[source]
provider = "github"
username = "your-github-username"
# token = "ghp_xxx"         # or use GIST_SYNC_SOURCE_TOKEN env var

[source.filters]
visibility = "all"          # all, public, private
# include_patterns = ["terraform", "aws"]
# exclude_patterns = ["temp", "wip"]
# since = "2024-01-01T00:00:00Z"
# gist_ids = ["abc123"]     # sync only these (ignores other filters)

[[targets]]
name = "gitlab-personal"
provider = "gitlab"
enabled = true
username = "your-gitlab-username"
# token = "glpat-xxx"       # or GIST_SYNC_TARGET_GITLAB_PERSONAL_TOKEN
# base_url = "https://gitlab.example.com"  # for self-hosted
on_conflict = "update"      # skip, update, replace
preserve_description = true
description_prefix = ""
description_suffix = ""
visibility_mode = "preserve" # preserve, public, private, internal
delete_orphans = false

[[targets]]
name = "codeberg"
provider = "codeberg"
enabled = true
username = "your-codeberg-username"
on_conflict = "update"
preserve_description = true
description_prefix = ""
description_suffix = ""
visibility_mode = "preserve"
delete_orphans = false

[[targets]]
name = "bitbucket"
provider = "bitbucket"
enabled = false
username = "your-username"
workspace = "your-workspace"  # required for Bitbucket
on_conflict = "update"
preserve_description = true
description_prefix = ""
description_suffix = ""
visibility_mode = "preserve"
delete_orphans = false

[[targets]]
name = "keybase"
provider = "keybase"
enabled = false
username = "your-keybase-username"
# team = "team-name"        # optional, for team repos
on_conflict = "update"
preserve_description = true
description_prefix = ""
description_suffix = ""
visibility_mode = "public"
delete_orphans = false

[hooks]
# pre_sync = "echo 'Starting...'"
# post_sync = "notify-send 'Gist sync complete'"
# on_error = "echo 'Failed' | mail -s 'Error' admin@example.com"
```

## Authentication

### Environment Variables (Recommended)

```bash
# Add to ~/.bashrc, ~/.zshrc, or ~/.config/environment.d/gist-sync.conf

# Source token (GitHub)
export GIST_SYNC_SOURCE_TOKEN="ghp_xxxxxxxxxxxx"

# Target tokens - pattern: GIST_SYNC_TARGET_<NAME>_TOKEN
# NAME is uppercase, hyphens become underscores
export GIST_SYNC_TARGET_GITLAB_PERSONAL_TOKEN="glpat-xxxxxxxxxxxx"
export GIST_SYNC_TARGET_CODEBERG_TOKEN="xxxxxxxx"
export GIST_SYNC_TARGET_BITBUCKET_TOKEN="xxxxxxxx"
```

### Required Token Permissions

| Provider  | Scope/Permission                          |
|-----------|-------------------------------------------|
| GitHub    | `gist` (read)                             |
| GitLab    | `api` or `write_snippet`                  |
| Codeberg  | `write:repository`                        |
| Gitea     | `write:repository`                        |
| Bitbucket | App password with `snippets:write`        |
| Keybase   | Local CLI login (`keybase login`)         |

## Usage

### Commands

```bash
# Synchronize gists (default command)
gist-sync sync
gist-sync                    # equivalent

# List source gists
gist-sync list

# List configured targets
gist-sync targets

# Validate configuration
gist-sync validate
```

### Options

```bash
-c, --config FILE    Use custom config file
-n, --dry-run        Preview without making changes
-v, --verbose        Enable debug output
-q, --quiet          Show errors only
-h, --help           Show help
--version            Show version
```

### Examples

```bash
# Standard sync
./gist-sync.sh sync

# Dry-run to preview
./gist-sync.sh --dry-run sync

# Use custom config
./gist-sync.sh -c ~/my-config.toml sync

# Verbose output for debugging
./gist-sync.sh -v sync

# Quiet mode for cron
./gist-sync.sh -q sync
```

### Example Output

```
[2026-01-01 13:00:08] [INFO ] Loaded 1 targets
[2026-01-01 13:00:08] [INFO ] Fetching gists from username on GitHub...
[2026-01-01 13:00:08] [INFO ] Total gists after filters: 31
[2026-01-01 13:00:08] [INFO ] Starting sync of 31 gists to 1 targets...
[2026-01-01 13:00:08] [INFO ] [1/31] Gist: Git Global Configs...
[2026-01-01 13:00:09] [INFO ]   → GitLab (gitlab-personal): git-global-configs
[2026-01-01 13:00:10] [OK   ] Created: git-global-configs
[2026-01-01 13:00:11] [INFO ] [2/31] Gist: Terraform AWS Module...
[2026-01-01 13:00:12] [INFO ]   → GitLab (gitlab-personal): terraform-aws-module
[2026-01-01 13:00:13] [OK   ] Updated: terraform-aws-module
...
[2026-01-01 13:05:00] [INFO ] Sync complete: 31 successful, 0 errors
```

## Naming Convention

Each provider uses different terminology for code snippets:

| GitHub (source) | GitLab    | Gitea/Codeberg  | Bitbucket | Keybase       |
|-----------------|-----------|-----------------|-----------|---------------|
| Gist            | Snippet   | Repo `gist-*`   | Snippet   | Repo `gist-*` |

The identifier at the destination is derived from:
1. Gist description (sanitized: lowercase, special chars → hyphens, max 50 chars)
2. First filename without extension (if no description)
3. Truncated gist ID (fallback)

## Conflict Resolution

| `on_conflict` | Behavior                                          |
|---------------|---------------------------------------------------|
| `skip`        | Don't modify if already exists at target          |
| `update`      | Update content, keep target metadata              |
| `replace`     | Completely replace with source version            |

## Automation

### Cron

```bash
# Run every 6 hours
crontab -e
0 */6 * * * /usr/local/bin/gist-sync -q sync 2>&1 | logger -t gist-sync
```

### Systemd Timer

```ini
# ~/.config/systemd/user/gist-sync.service
[Unit]
Description=Gist Sync
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/gist-sync sync
Environment="GIST_SYNC_SOURCE_TOKEN=ghp_xxx"
Environment="GIST_SYNC_TARGET_GITLAB_PERSONAL_TOKEN=glpat_xxx"

[Install]
WantedBy=default.target
```

```ini
# ~/.config/systemd/user/gist-sync.timer
[Unit]
Description=Gist Sync Timer

[Timer]
OnCalendar=*-*-* 00,06,12,18:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now gist-sync.timer
systemctl --user list-timers
```

## Code Structure

```
gist-sync.sh (≈1900 lines)
├── Constants and globals
├── log::*           # Logging (debug, info, warn, error, success)
├── util::*          # Utilities (die, require_command, expand_path)
├── toml::*          # TOML parser (supports Go yq and Python tomlq)
├── config::*        # Configuration loading and validation
├── http::*          # HTTP client (GET, POST, PUT, DELETE)
├── github::*        # GitHub provider (source)
├── gitlab::*        # GitLab provider (PRIVATE-TOKEN auth)
├── gitea::*         # Gitea/Codeberg/Forgejo provider
├── bitbucket::*     # Bitbucket provider
├── keybase::*       # Keybase provider (CLI + git)
├── sync::*          # Sync orchestration
├── cli::*           # CLI parsing and commands
└── main             # Entry point
```

## Troubleshooting

### Common Issues

**"No TOML parser found"**
```bash
# Install Go yq
sudo dnf install yq        # Fedora
brew install yq            # macOS

# OR Python yq
pip install yq
```

**"source.username not configured"**
- Check your `config.toml` syntax
- Ensure you're using `[[targets]]` (plural) not `[[target]]`
- Run `./gist-sync.sh -v validate` for debug output

**"HTTP 401: Unauthorized"**
- Verify token has required permissions
- Check token hasn't expired
- Ensure correct environment variable name (uppercase, hyphens → underscores)

**"HTTP 429: Too Many Requests"**
- Increase `rate_limit_interval` in config
- Reduce number of gists with filters

### Debug Mode

```bash
# Verbose logging
./gist-sync.sh -v sync

# Validate configuration
./gist-sync.sh validate

# Test TOML parsing
yq -p toml -o json config.toml | jq '.source'
```

## Limitations

- **Gitea/Codeberg/Forgejo** — no native snippets API; uses repositories with `gist-` prefix
- **Keybase** — requires Keybase CLI installed and logged in
- **Bitbucket** — limited support for long descriptions
- **Rate limits** — respect each provider's API limits
- **Large files** — may hit API size limits on some providers

## Contributing

Contributions welcome! Feel free to submit issues and pull requests.

## License

MIT License — see [LICENSE](LICENSE) for details.

## Author

**Esli** — [esli.blog.br](https://esli.blog.br)

---

*If you find this useful, consider giving it a ⭐ on GitHub!*

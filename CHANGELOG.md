# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2025-01-15

### Added
- Initial release
- GitHub as source provider
- Target providers: GitLab, Codeberg, Gitea, Forgejo, Bitbucket, Keybase
- TOML configuration format
- Advanced filtering (visibility, date, patterns, specific IDs)
- Conflict resolution strategies (skip, update, replace)
- Description transformation (prefix, suffix)
- Visibility control (preserve, force public/private)
- Lifecycle hooks (pre_sync, post_sync, on_error)
- Dry-run mode
- Configurable rate limiting
- Colored terminal output
- Comprehensive logging with levels
- CLI with multiple commands (sync, list, targets, validate)

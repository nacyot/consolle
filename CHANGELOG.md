# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.5] - 2025-01-24

### Fixed
- Handle UTF-8 encoding for strings tagged as ASCII-8BIT when processing multibyte characters

### Changed
- Minimum Ruby version requirement changed from 3.0.0 to 3.1.0
- Updated gemspec metadata for RubyGems.org publishing

### Added
- bin/consolle executable for gem exec support
- MIT License file
- GitHub Actions CI workflow for testing across multiple Ruby versions and platforms
- Release script for automated versioning and publishing

## [0.2.4] - 2025-01-23

### Added
- Initial release with PTY-based Rails console management
- Multi-session support
- Socket-based communication
- Automatic console restart on failure

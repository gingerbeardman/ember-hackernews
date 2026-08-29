# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- Discussion header matches Hacker News: the title opens the article, with the full article URL as a second link underneath. The large site card is gone.
- Show Story Thumbnails now also applies on the discussion: a small favicon beside the URL when the setting is on, nothing extra when it's off.
- Story upvote and comment actions sit on one line without the Comment label wrapping.
- Headlines wrap more evenly, keeping a short last word from sitting alone on its own line.

### Fixed
- Tapping a saved-search notification from the lock screen opens the story in the app.
- Opening a story that matched a saved search marks that notify as read (inbox, badge, and the banner).
- Downvoting a comment no longer pops open a Hacker News web view.
- Open in Hacker News opens the real news.ycombinator.com page in a web view, instead of the in-app discussion.

### Removed
- Downvote on stories. Hacker News only offers downvotes on comments.

## [1.3.0] - 2026-06-22

### Fixed
- Mac Catalyst no longer crashes on first launch from a missing `SettingsStore` in presented views (#1). The Observation stores are now re-injected across the onboarding full-screen cover and desktop Settings sheet boundaries.
- Appearance reliably reverts to System after forcing Light or Dark, by driving the window's interface style directly (#9, thanks @gingerbeardman).
- Search no longer flashes a transient error while typing when an in-flight request is superseded or cancelled (#10, thanks @gingerbeardman).

### Added
- Per-story thumbnail toggle (Show Story Thumbnails) in Settings and onboarding (#8, thanks @gingerbeardman; closes #7).

### Changed
- `project.yml` no longer forces code signing off, so device builds sign normally while simulator builds still work without a team; added a README signing section (#12, thanks @gingerbeardman; addresses #6).

## [1.2.0] - 2026-06-21

### Added
- Adjustable reading text size: a control in Settings and pinch-to-zoom inside a discussion, applied on top of Dynamic Type.
- Privacy manifest (`PrivacyInfo.xcprivacy`) declaring no tracking, no data collection, and required-reason API usage, for App Store readiness.
- README privacy section documenting the official-APIs-only, no-account, no-tracking stance.

## [1.1.0] - 2026-06-20

### Added
- Mac and large-iPad support via Mac Catalyst, with an adaptive three-pane layout (sidebar, story list, discussion) on regular-width windows.
- Offline reading: a bounded JSON disk cache for feed lists, story items, and comment trees, served automatically as a fallback when offline. Cache size and a clear action are in Settings.
- Reading typography set in the bundled Inter font, scaled with Dynamic Type, with comfortable leading and a constrained reading measure.
- A dedicated share button in the story toolbar (article or discussion link).

### Changed
- Higher-contrast metadata text and more generous spacing in Settings and the feed.
- Compact, branded feed header that reclaims vertical space.

## [1.0.0] - 2026-06-20

### Added
- Story feeds: Top, New, Best, Ask HN, Show HN, and Jobs with a pinned filter bar, pull-to-refresh, and pagination.
- Story detail with a native-rendered comment thread: collapsible threads, depth indicators, tappable links, quotes, and code blocks, loaded in a single Algolia request.
- Full-text search across Hacker News by relevance or recency.
- Saved stories with on-device persistence and offline access.
- Read-state tracking that dims visited stories.
- In-app Safari reader with optional Reader mode, or system-browser hand-off.
- User profiles with karma, join date, about, and recent submissions.
- Smart first-run onboarding that detects device appearance and accessibility settings, pre-configures the app, and previews choices live.
- Accessibility: color-independent status cues, VoiceOver labels and custom actions, Dynamic Type, Reduce Motion support, and underlined links.
- Six accent themes, full light/dark support, haptics, and a generated app icon.

[1.3.0]: https://github.com/DatanoiseTV/ember-hackernews/releases/tag/v1.3.0
[1.2.0]: https://github.com/DatanoiseTV/ember-hackernews/releases/tag/v1.2.0
[1.1.0]: https://github.com/DatanoiseTV/ember-hackernews/releases/tag/v1.1.0
[1.0.0]: https://github.com/DatanoiseTV/ember-hackernews/releases/tag/v1.0.0

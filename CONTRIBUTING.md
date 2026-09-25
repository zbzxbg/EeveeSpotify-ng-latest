# Contributing

Thank you for using this project. Feature requests can be submitted for free (so you don’t need to pay, but new features will be added at the project’s discretion).

## Before you open an issue

Please use the issue templates.

- **Bug reports** go through the bug report template. It will ask for:
  - installation type (jailbreak / TrollStore / sideloaded IPA, etc.)
  - Spotify version
  - EeveeSpotify version
  - iOS / iPadOS version
  - affected area
  - a debug log from the tweak settings if relevant
- **Feature requests** go through the feature request template.
- Before filing anything, check [common_issues.md](common_issues.md). Features that are server-sided are not something this tweak can fix.

If you are reporting a crash or a feature regression, include the Spotify build number when you can. Version matters a lot here.

## Version sensitivity

EeveeSpotify hooks private classes, selectors, and response shapes that can change between Spotify releases. That means:

- A change that works on one Spotify version may not be safe on another.
- If you are relying on a specific class or selector being present, note that assumption in your change description.

The more explicit you are about the target version, the easier it is for maintainers to evaluate and handle it without silently breaking another build.

## Translations

Translations are welcome. The translation workflow is described in [TRANSLATING.md](TRANSLATING.md), and there is a checker in `Tools/l10n_lint.py` that validates translations before they are submitted.

If you are contributing or updating a localization, run the checker and include its result when submitting. That saves review time and prevents obvious issues from landing.

## Pull requests

This project does not currently support pull requests.
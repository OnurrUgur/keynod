# Contributing to Keynod

Thanks for helping. Keynod guards people's API keys, so changes are reviewed with care and small pull requests land fastest.

## Build and test

You need macOS 14+, Xcode 16+ and XcodeGen (`brew install xcodegen`).

```bash
make test     # unit tests, no Apple Developer Team ID needed
```

To run the app itself you need your own Team ID; see "Install" in the README. Never commit `Local.xcconfig`: it is git-ignored and holds your Team ID.

## Pull requests

- One change per pull request, with a short description of what and why.
- Add or update tests for behaviour you change. `make test` must pass; CI runs it, builds both apps and scans for secrets.
- Keep the security model intact. Anything touching `CLIServer.swift`, `CLI.swift`, `PeerIdentity.swift`, `SecureChannel.swift`, `ChannelKey.swift`, `ApprovalText.swift`, the `Shared/Link*` files or the iPhone keys needs a note on how it affects the threat model in `SECURITY.md`.
- No new dependencies, network calls, analytics or telemetry.
- Never put a real key, token or password in code, tests, issues or screenshots. Test fixtures are built from pieces so scanners don't flag them; follow that pattern.

## Security issues

Do not open a public issue. Report privately through GitHub Security Advisories ("Report a vulnerability" on the Security tab). See `SECURITY.md`.

## Licence

By contributing you agree that your contribution is licensed under the MIT licence of this project.

<p align="center"><img src="docs/icon-256.png" width="128" height="128" alt="Keynod icon"></p>

# Keynod

An open-source, serverless **biometric secret vault & AI coding agent approval gate** for macOS and iPhone.

Store API keys, logins, and `.p8`/private key files in your Mac's Data Protection Keychain, hand them to commands through environment variables or `0600` files instead of pasting them into an AI coding agent's chat (like Claude Code), and approve secret access or Claude Code tool prompts with **Touch ID** on your Mac or **Face ID** on your iPhone over your private iCloud. There is no Keynod server and no subscription.

Masking and the Claude Code guard catch accidents; they don't stop a command you approved from using the secret however it likes. See [SECURITY.md](SECURITY.md) for exactly what is and isn't protected.

## Why Keynod?

If you know the 1Password CLI: `op run` and `op inject` do the same job of handing secrets to a command (and `op run` masks them in its output), with your vault in a 1Password account. Keynod keeps the vault on your Mac, and adds:

| Feature | Keynod |
| --- | --- |
| `run` / `inject` for environment variables and `0600` files | `keynod run`, `keynod inject` |
| Secret values masked in command output | when the output isn't a terminal (`<concealed>`) |
| Touch ID approval naming the program, its arguments, the directory and the caller | yes; `get` always asks, and inside Claude Code so do `run` and `inject` |
| Refuses to print a value inside a Claude Code session (guardrail) | `keynod get --reveal` |
| Only its own CLI may use the local socket (code signature and a keychain-held channel key, Team-signed builds) | yes |
| iPhone Face ID approvals over your private iCloud, no server | yes |
| Claude Code hooks (`PermissionRequest`, `Stop`, `AskUserQuestion`) to the iPhone | yes |
| Key Catcher: notices copied API keys (fal.ai, OpenAI, Anthropic, GitHub, AWS, PEM and more) | yes |
| Cost and account | free, MIT; local Keychain and your private iCloud |

## Install

You need a Mac with Touch ID (or a password), Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) and an Apple Developer Team ID. The tested path is a paid Apple Developer Program membership; a free Apple ID's personal team may work for the Mac app but hasn't been tested, and the iPhone app's iCloud link needs the paid program. Add your account in Xcode → Settings → Accounts; the Team ID is the 10-character code shown for your team (also on [developer.apple.com/account](https://developer.apple.com/account) under Membership).

```bash
git clone https://github.com/OnurrUgur/keynod.git && cd keynod
cp Local.xcconfig.example Local.xcconfig
```

Edit `Local.xcconfig` (it is git-ignored, so your Team ID never ends up in the repo):

```
KEYNOD_TEAM_ID = ABCDE12345                       // your Team ID
KEYNOD_BUNDLE_PREFIX = com.yourname.keynod        // any reverse-DNS prefix you own
KEYNOD_ENTITLEMENTS = Keynod/KeynodMac.entitlements  // Mac only, no iCloud
```

Then build and install:

```bash
make install   # builds, copies to /Applications/Keynod.app, starts it, links ~/.local/bin/keynod
keynod list    # "no secrets" means the command reaches the app
```

Make sure `~/.local/bin` is on your `PATH` (`echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc`).

Why a Team ID: the Vault lives in the Data Protection Keychain, and macOS only lets apps signed with a keychain access group use it. A build without one starts and shows an alert, but every save and read fails with `-34018`, so `make build` and `make install` stop early when `KEYNOD_TEAM_ID` or `KEYNOD_ENTITLEMENTS` is empty. `make test` needs no Team ID.

To uninstall: run `keynod hooks uninstall` if you installed the hooks, then quit Keynod and delete `/Applications/Keynod.app`, `~/.local/bin/keynod` and `~/Library/Application Support/Keynod`.

## CLI Reference

`make link` (included in `make install`) symlinks `~/.local/bin/keynod` to the app binary. It talks to the running app over a `0600` Unix socket (`keynod.sock`) and never touches the Vault itself. Both ends check the other's code signature, then seal every request and answer with a channel key kept in the app's keychain access group. Scripts must go through `keynod`, not the socket. This holds for Team-signed, hardened builds: a Debug build signed by the same team counts as the app, and a build without a Team ID keeps the channel key in a `0600` file that any of your processes can read.

`keynod run` finds the program the way the shell would, resolves symlinks, and runs exactly that file; if the file changes while you approve, nothing runs. The approval names it (the file name always in full), and `inject` names the file it will write. The command runs with your environment (`PATH`, `NODE_OPTIONS`, …): that isn't shown, but a changed environment asks again.

```bash
# List secrets and field labels (concealed values are never printed)
keynod list [--json] [query...]

# Create or permanently delete secrets (always prompts for Touch ID / Face ID).
# A --concealed field without "=value" is typed without echo (or read from stdin), so the
# key never sits in the process list or your shell history.
keynod secret add --title "Anthropic" [--details "Production #ai"] \
  [--field "Org=acme"] [--concealed "Key"] [--file "Cert=./key.p8"]
keynod secret delete <id or full title>...

# Run a command with secrets injected into env vars or 0600 temp files
# Non-TTY stdout/stderr replaces secret values with <concealed>
keynod run --env ANTHROPIC_API_KEY="Anthropic/Key" --file P8="App Store Connect/Private Key" -- fastlane beta

# Write a secret to a 0600 file (warns if inside git and not ignored)
keynod inject "Stripe/Live Key" --to .env.local [--force]

# Print a secret value to stdout (refused when called inside a Claude Code session)
keynod get "Anthropic/Key" --reveal

# Ask your paired iPhone directly from scripts
keynod decide "Deploy to production?" --option Yes --option No [--text] [--timeout 30m]
keynod code "GitHub" [--timeout 10m]
```

A `ref` is `"<secret>/<field>"` (e.g. `"Anthropic/Key"` or `"<uuid>/Private Key"`). Secrets match by UUID or case-insensitive unique title substring.

The list of secrets (`vault.json`) carries a seal only the app can make. If it changes outside the app, `keynod` releases nothing until you've checked the list in the Vault and chosen **Keynod › Trust Current Vault…** (Touch ID). A request whose fields or command arguments don't fit the Touch ID dialog in full is refused; split it into smaller commands or put long arguments in a script.

## Using Keynod with AI coding agents

Any agent that can run shell commands can use Keynod: Claude Code, Antigravity, Codex, Cursor, Gemini CLI and others. The agent never needs to see a secret. It names the secret, Keynod asks you, and the value goes straight into the command.

1. Store the secret once: `keynod secret add --title "OpenAI" --concealed "Key"` (you type the key, it isn't echoed), or copy the key and press **Save to Vault** on the Key Catcher card.
2. Tell the agent how to use it. Paste this into the file your agent reads for project or global instructions: `CLAUDE.md` for Claude Code, `AGENTS.md` for Codex and most others, `GEMINI.md` or Antigravity's rules for Gemini-based agents.

```markdown
## Secrets (Keynod)
- API keys and credentials live in Keynod. Run `keynod list` to see what exists: names, field labels and non-secret values only.
- Use a secret without reading it: `keynod run --env VAR="<secret>/<field>" -- <command>`, or write it to a git-ignored file with `keynod inject "<secret>/<field>" --to <path>`. The user approves each use with Touch ID.
- Never print or read secret values, never use `keynod get`, and never paste a key into the chat or a file that is committed.
- If more than one secret could fit, ask the user which one.
```

What works the same for every agent: the Touch ID or iPhone approval naming the exact command, and `<concealed>` masking in captured output. Inside Claude Code every `run` and `inject` asks again: there is no repeat window, because an agent can change what an approved command reads (a script, a Makefile) and run it once more. Outside Claude Code, the identical command from the same shell may repeat for 5 minutes without asking; other agents aren't recognised, so they get that window too.

What is Claude Code only: the [hooks](#claude-code-hooks) below, and the guard that refuses `keynod get --reveal` inside an agent session (Keynod recognises Claude Code's process; other agents are not detected). With other agents, the instruction above is what keeps them away from `get`.

## Claude Code Hooks

Hooks connect Claude Code to your iPhone: its permission prompts, questions and plan approvals come to the phone while you are away from the Mac. Install them once; they stay quiet until you turn on Remote Mode.

```bash
keynod hooks install     # or Keynod Settings -> Claude Code Hooks -> Install
keynod hooks status
keynod hooks uninstall   # removes only Keynod's entries; keeps a timestamped backup
```

When **Remote Mode** is on:
- **`PermissionRequest`**: Tool approval prompts (e.g. `Bash`, `Write`) go to your iPhone with Face ID Allow / Deny, but only when the whole tool call fits the card (summary up to 300 characters, details up to 1,500). A longer one, such as most `Write` and `Edit` calls, stays on the Mac as Claude Code's own prompt, because Allow would cover text the phone never showed.
- **`PreToolUse` (`AskUserQuestion`, `ExitPlanMode`)**: Multi-choice questions and plan approvals render as interactive cards on your iPhone.
- **`Stop`**: When Claude finishes a turn with a question, reply directly from your iPhone to continue the session.

When Remote Mode is off, Keynod isn't running, the socket is held by a program that isn't Keynod, or `KEYNOD_HOOKS_OFF=1` is set, the hooks exit silently so Claude Code behaves normally.

Questions sent to the iPhone (the Bash command, Claude's last message) travel through iCloud and the push notification in readable text. Keynod replaces the secrets Key Catcher recognises with a marker before they leave the Mac, but that is best effort.

## iPhone Face ID Approvals

```bash
# In Local.xcconfig: KEYNOD_TEAM_ID, KEYNOD_BUNDLE_PREFIX, KEYNOD_ICLOUD_CONTAINER (registered to your team),
# and KEYNOD_ENTITLEMENTS = Keynod/Keynod.entitlements
make install
make phone     # builds and installs KeynodPhone on your connected iPhone
```

1. Open **Keynod Settings → iPhone Approvals → Pair iPhone…** on your Mac.
2. Scan the QR code with Keynod on your iPhone, verify the 6-digit pairing code matches on both screens, and confirm with Touch ID.
3. Toggle **Remote Mode** from the Mac top bar, menu bar popover, or iPhone app when stepping away.

## Key Catcher

When enabled (default), Keynod watches the pasteboard change count (without recording any clipboard history) and shows a non-activating floating card whenever you copy an API key, token, JWT, or PEM private key — including Anthropic, OpenAI, OpenRouter, **fal.ai**, Groq, Perplexity, Replicate, Hugging Face, ElevenLabs, GitHub, AWS, Stripe, Slack, Google, Supabase, Resend, Linear, npm, PyPI, Figma, Sentry, PostHog, Doppler, and Telegram bot tokens.

## Security

See [SECURITY.md](SECURITY.md) for the threat model (what Keynod protects against and what it doesn't), the Keychain storage model, and the iPhone cryptography.

## License

[MIT](LICENSE)

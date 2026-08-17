# Mousi

**Highlight text anywhere on your Mac → a tiny Liquid Glass pill appears at your cursor → copy it, fix it, or turn it into a great AI prompt.**

Mousi is a native macOS menu bar app written in Swift (AppKit + SwiftUI). It removes the little frictions of working with text and AI all day: no ⌘C, no right‑click, no switching to a chat window just to fix a sentence.

<p align="center">
  <img src="docs/compact.png" width="380" alt="The Mousi pill: Copy, Rewrite, Prompt">
</p>

## What it does

There is no preview step. You click the action you want and the result is written straight back over your selection — ⌘Z undoes it, and holding ⌥ copies instead of replacing.

| Action | What happens |
|---|---|
| **Copy** | Copies the highlighted text. One click, from any app. |
| **✦ Professional** | The primary, one‑click action: fixes every grammar/spelling/punctuation error and makes the text clear and professional, at the same length and in your own voice. |
| **Friendly** | Same fix, but warm and personable — professional without sounding like a form letter. |
| **⋯** | **Enhance as AI prompt** (rewrite a rough request as a sharper prompt), **Draft a reply**, **Shorten**, **Expand**, **Summarize**, **Make bullets**, **Simplify**, and **Before I send…** — a pre‑send check that flags leaked secrets or personal data, accidental commitments, a tone that reads badly, and claims the text doesn't support. |

<p align="center">
  <img src="docs/working.png" width="30%" alt="Working state">
  &nbsp;
  <img src="docs/done.png" width="27%" alt="Replaced confirmation">
  &nbsp;
  <img src="docs/note.png" width="38%" alt="Before I send check">
</p>

The pill fades away when you click elsewhere, type, scroll, or switch apps. Everything is designed to stay small and out of the way.

## Highlights

- **Native Liquid Glass UI** — built on macOS 26's `glassEffect`, follows Apple's guidance (one glass surface per element, plain high‑contrast content inside, adaptive light/dark).
- **Works in every app** — global mouse tracking + the Accessibility API to read the selection; a clipboard‑borrowing fallback for apps that don't expose it (clipboard is restored afterwards).
- **Bring your own model** — your **Claude subscription** through the Claude Code CLI (no API key needed), an **Anthropic API key**, or **OpenRouter** for one key across many models. Defaults to Haiku for speed and cost.
- **Fast** — a single plain‑text completion per action, a hard word budget computed from your selection, and no preview to read: **~2.1 s** from click to text on screen (measured across eight actions).
- **Written back in place** — via the Accessibility API where possible, so the clipboard is never touched and the change lands in the app's own undo stack; falls back to paste, then to copy for read‑only text.
- **Zero build tooling** — no Xcode project. `swiftc` + a shell script produce a signed `.app` with a generated icon.
- **Menu bar only** — on/off toggle, launch at login, settings; no Dock icon.

## Getting started

Requires **macOS 26 Tahoe** and the Xcode Command Line Tools.

```sh
git clone https://github.com/JuniorSua/mousi.git && cd mousi
./Tools/make-signing-identity.sh   # once: creates a local self-signed signing identity
./build.sh --install               # builds, installs to /Applications, launches
```

Then:
1. Grant **Accessibility** access when macOS asks (System Settings → Privacy & Security → Accessibility → Mousi). This is what lets Mousi see what you highlighted.
2. Open **Mousi → Settings…** and press **Test**. If you have [Claude Code](https://claude.com/claude-code) installed and signed in, it just works on your subscription. Otherwise switch to "Anthropic API key" or "OpenRouter" and paste a key.
3. Highlight some text.

> Why the signing step? macOS ties the Accessibility grant to the app's code identity. Ad‑hoc signatures change on every build, which silently revokes it; a stable local certificate keeps the grant across rebuilds.

## How it's built

```
Sources/
  main.swift             app delegate, menu bar item, settings window
  SelectionMonitor.swift global mouse tracking, Accessibility text capture, clipboard helpers
  PillController.swift   the floating non‑activating panel: positioning, sizing, phases, actions
  PillViews.swift        SwiftUI Liquid Glass views (pill, transient states, note card)
  Actions.swift          every action: label, icon, system prompt, length budget
  ClaudeClient.swift     backend dispatch, word budgets, output sanitising + Anthropic API path
  ClaudeCLI.swift        subscription backend: runs `claude -p` as a subprocess
  OpenRouterClient.swift OpenRouter backend, falls back to Claude when unavailable
  PromptEnhancer.swift   the prompt‑engineering system prompt
  Settings.swift / SettingsView.swift
Tools/
  MakeIcon.swift             draws the app icon with CoreGraphics
  make-signing-identity.sh   local code‑signing identity
build.sh                     compile → bundle → icon → sign → (install)
```

A few of the interesting problems solved along the way:

- **A panel that never steals focus.** The pill is a borderless `NSPanel` with `.nonactivatingPanel`, so your cursor and selection stay exactly where they were — which is what makes one‑click replacement possible at all.
- **Detecting "you just selected something."** A global monitor watches mouse down/up; a drag longer than a few points or a double/triple‑click triggers a short delayed read of the focused element's `AXSelectedText`.
- **Not confusing itself.** The synthetic ⌘C/⌘V events Mousi sends are tagged so its own key monitors ignore them.
- **Cheap and fast AI.** Rewrites run on Haiku with thinking capped, via the CLI the user is already logged into — no keys to manage, roughly a fraction of a cent per use. Asking for one plain‑text result instead of three JSON ones cut latency ~40%.
- **Making a small model obey a length limit.** "Keep it about twice the length" is ignored; the app counts the words in your selection and states an exact cap in the prompt. That alone took prompt‑enhancement bloat from 4.6× the original down to 2.0×.

## Privacy

Mousi only reads text when you actively highlight it, and only sends it anywhere when you click one of the AI actions — Copy never leaves your Mac. Nothing is logged or stored by the app. Your API key (if you use one) lives in the app's local preferences on your Mac.

## License

MIT — see [LICENSE](LICENSE).

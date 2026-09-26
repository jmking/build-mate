# Instructions for agents working on Build Mate

## Read before you build
1. `docs/spec/00-index.md`, then the spec file for the area you are working on.
2. The matching screens in `docs/design/png/light` and `docs/design/png/dark`. For exact spacing, sizes and colours, open the static HTML in `docs/design/html/` (it renders in any browser; values are in inline styles).
3. `docs/spec/06-design-system.md` for tokens, materials and SF Symbol mappings.

## Ground rules
- Build what is in scope for the current version (`docs/spec/07-delivery.md`). Designs for later versions are included for context; do not build them early.
- The designs are references rendered in HTML. Build them with native SwiftUI/AppKit controls, system materials (Liquid Glass), SF Symbols and system colours, not by copying CSS. Where the HTML and Apple's Human Interface Guidelines disagree, follow the HIG and note it.
- Sample data in the designs (task names, numbers, people, PR numbers) is illustrative.
- Never write Build Mate's own files into a user's repository. All project data lives in Build Mate's storage (`docs/spec/02-architecture.md`, Storage).
- Treat every integration marked "verify in spike" as unconfirmed until you have tested it against the real tool. Record what you find in `docs/spec/08-open-questions.md`.
- Every feature has acceptance criteria in `docs/spec/07-delivery.md`. A feature is done when those pass, in light and dark mode, with VoiceOver labels and keyboard access.
- Keep secrets (tokens, keys) in the macOS Keychain or with the CLI that owns them. Never log or commit them.

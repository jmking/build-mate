# Build Mate specification

| # | Document | Covers |
|---|---|---|
| 01 | [Product](01-product.md) | Problem, principles, users, concepts, glossary, non-goals |
| 02 | [Architecture](02-architecture.md) | Components, storage, data model, task lifecycle, orchestration, prompts, proof, preview, concurrency, pause, approvals, notifications, security, remote access |
| 03 | [Integrations](03-integrations.md) | Codex app-server, GitHub (`gh`), Bitbucket Cloud (TWG CLI), editors, the Build Mate agent tools (MCP) |
| 04 | [Mac UX](04-ux-mac.md) | Information architecture, navigation, every Mac screen, menus, shortcuts |
| 05 | [iPhone UX](05-ux-iphone.md) | iPhone Pro and iPhone Duo screens |
| 06 | [Design system](06-design-system.md) | Colours (light/dark), typography, spacing, radii, materials, SF Symbols, motion, accessibility |
| 07 | [Delivery](07-delivery.md) | Versions, milestones, acceptance criteria |
| 08 | [Open questions and spikes](08-open-questions.md) | Things to verify before or during build |

Designs: [../design/README.md](../design/README.md).

## How to read this spec
- **MUST / SHOULD / MAY** have their usual meanings.
- `v1`, `v1.1`, `v2`, `v3` tags mark when a feature ships. Untagged means v1.
- "Symphony" always refers to OpenAI's orchestration spec (`openai/symphony`, `SPEC.md`). The product is **Build Mate**.

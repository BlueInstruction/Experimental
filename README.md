# vkd3d-proton-wcp

Experimental VKD3D-Proton builds for Windows on ARM64EC.

## Releases

- [VKD3D-Proton ARM64EC 3.0b — 20260403](https://github.com/BlueInstruction/vkd3d-proton-wcp/releases) (Latest)

## Qoder Integration

This repository uses [Qoder](https://docs.qoder.com/cli/qoder-action) for automated code review and AI-assisted bug fixing.

### Features

- **Automated PR Review** — Every pull request targeting `main` is automatically reviewed by Qoder.
- **AI Assistant** — Comment `@qoder` in any PR or issue to ask for help fixing bugs or reviewing code.

### Setup

See [SETUP_QODER.md](SETUP_QODER.md) for full setup instructions, including:

1. Installing the Qoder GitHub App on this repository
2. Adding the `QODER_PERSONAL_ACCESS_TOKEN` secret
3. Verifying the workflows are active

### Workflows

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `qoder-review.yml` | Pull requests to `main` | Automated code review |
| `qoder-assistant.yml` | `@qoder` comments | AI-assisted fixes |

## License

[MIT](LICENSE)

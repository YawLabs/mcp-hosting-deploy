# Contributing to mcp-hosting-deploy

Thanks for your interest in contributing! This repo contains deployment templates for the [mcp.hosting](https://mcp.hosting) platform.

## What to contribute

- New deployment targets (cloud providers, platforms)
- Improvements to existing templates (security, performance, usability)
- Documentation fixes and additions
- Bug reports

## How to contribute

1. Fork this repository
2. Create a feature branch: `git checkout -b my-feature`
3. Make your changes
4. Test your deployment template if possible
5. Submit a pull request

## Guidelines

- Keep templates self-contained per deployment target
- Use sensible defaults that are safe for production
- Never commit secrets or credentials, even as examples with real-looking values
- Document required variables and prerequisites in a README
- Follow existing naming conventions and file structure

## Reporting issues

Open an issue on GitHub with:
- Which deployment template you're using
- What you expected vs. what happened
- Any relevant logs (redact secrets)

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](./LICENSE).

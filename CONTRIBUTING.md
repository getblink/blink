# Contributing

Thanks for taking a look at Blink. Blink is source-available under the Elastic License 2.0, not OSI open source; see [LICENSE](LICENSE) before relying on the code in another project.

## Build And Test

- macOS app: see [app/README.md](app/README.md).
- Backend server: see [server/README.md](server/README.md).
- Landing page: see [site/README.md](site/README.md).

Useful checks:

```bash
python3 -m unittest discover app/python/tests
cd server && pytest
cd site && npm run build
```

## Issues

File issues with a short repro, your macOS version, Blink version, and the app or website where the problem happened. Screenshots or run-bundle notes are helpful when they do not contain private content.

Do not open public issues for security findings. Email henry@useblink.dev instead.

## Pull Requests

Open focused PRs against `main`. Keep changes small, explain the behavior change, and include the commands you ran. If a change touches the client/server protocol, preserve the existing `/v1/tldr` compatibility surface unless the issue explicitly calls for a protocol break.


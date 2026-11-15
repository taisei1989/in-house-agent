# Security model

In-House Agent is a personal macOS application, not a sandbox for untrusted code. The local agent and its tools run with the signed-in user's permissions. Use a dedicated workspace with only the files the task needs.

## Local processing and network access

Chat inference uses the configured local LiteRT-LM model by default. Google and OpenAI-compatible cloud providers are optional and off by default. Enabling a provider sends prompts and tool results to that provider after the server is started. Configuration changes immediately disable sending and stop the running server; there is no silent cloud fallback. The active connection mode remains visible in the sidebar. Routines are local-only and reject a shared cloud server.

Provider API keys are stored in Keychain and passed to the sidecar through the bootstrap pipe, never arguments or preferences. The OpenAI-compatible adapter attaches credentials in a limited loopback proxy because this SDK version has no API-key parameter for that endpoint. The proxy accepts only the expected completion route, uses a random capability path, rejects browser Origins, enforces a request size limit, verifies upstream HTTPS, and does not follow redirects. Provider errors are not forwarded verbatim. Initial setup downloads Python packages and the model; update checks contact GitHub. Those network operations are not offline.

An approved shell command can read other files accessible to the user, contact the network, or start other programs. Approval does not make a command safe. The workspace checks on file tools are a defense against accidental out-of-workspace access, not an operating-system security boundary. Do not approve a command solely because a model says it is necessary. Model output and instructions found in files are untrusted input.

## Sidecar and approvals

- The HTTP listener binds to `127.0.0.1` on a dynamically allocated port.
- Every endpoint requires a per-launch random bearer token. Bootstrap passes the token through a pipe, not a command-line argument. Reuse by a routine uses Keychain; the port/PID descriptor contains no token.
- Browser requests with an `Origin` header are rejected. A malicious process running as the same macOS user is outside this protection boundary.
- Mutating tools and shell commands require an explicit approval tied to one pending operation. Timeout or disconnection denies pending approval. Unattended routines deny operations that require approval.
- Logs and routine results stay in Application Support. They can contain file names, prompts and model responses. Do not attach them to public issues without reviewing and redacting them.

## Updates and signing

Updates use Sparkle's EdDSA signatures. The public verification key is intentionally committed; the private signing key stays in the releasing user's Keychain. Both the appcast and update archive are signed and verified before release. The application requires a signed feed and verifies the archive before extraction.

The default build is ad-hoc signed for personal use. It is not Developer ID notarized and does not provide Apple's publisher attestation. A successful local launch is not evidence that a downloaded archive passes Gatekeeper. Never disable Gatekeeper globally to install this app.

Release publication requires a clean checkout, a release tag matching the current commit on GitHub, a matching Keychain/public signing key, and increasing version/build numbers. Python dependencies and Sparkle are version-pinned, but version pins alone do not constitute a supply-chain audit. Review dependency changes before rebuilding and releasing.

## Reporting a vulnerability

Do not post credentials, private documents, model transcripts or exploit details that expose a user's data in a public issue. If the repository's **Security → Report a vulnerability** action is available, use it. Otherwise, open a minimal issue requesting a private reporting channel, with no sensitive details. This personal project does not promise a response time or supported-version window.

If a signing key or GitHub publishing credential may have been compromised, stop publishing and investigate before issuing another update. Do not commit a replacement private key or silently replace the public key in an existing update channel.

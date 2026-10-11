# Global rules

Everything in this file is prepended to the system prompt of every session in
this container, for every project. It lives in the mounted config dir, so edits
survive a container restart.

Project-specific rules belong in an `AGENTS.md` at the project root instead.

<!-- Replace the example below with your own. -->

- Explain a plan before making large or destructive changes.
- Match the surrounding code's style instead of introducing a new one.

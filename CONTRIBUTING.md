# Contributing to tupoproxy

Thank you for improving tupoproxy. Changes to authentication, TLS emulation,
framing, relay loops, randomization, or concurrency are security-sensitive and
need focused review.

## Before opening an issue

- Search existing issues and the documentation.
- Include the tupoproxy version, operating system, deployment topology, and
  sanitized logs.
- Never post proxy secrets, API authorization headers, private keys, or public
  client IP addresses.
- Separate reproducible bugs from general deployment questions.

## Pull requests

Keep each pull request focused on one problem. Explain the failure mode, why the
change is safe, and which checks were run. Add a regression test before a bug
fix whenever practical.

Required local checks:

```bash
cargo check --locked --all-targets
cargo test --locked <relevant-test-or-module>
git diff --check
```

Do not run a repository-wide formatter as part of an unrelated change. Avoid
new allocations, blocking calls, or unrestricted logging in connection hot
paths. Preserve constant-time authentication comparisons and zeroization of
secret material.

## Documentation and compatibility

User-facing behavior and new configuration fields must be documented in both
configuration references. Call out breaking changes to metric names, file
paths, credentials, or service layouts explicitly.

By contributing, you agree that your change is distributed under the license
terms applicable to this repository.

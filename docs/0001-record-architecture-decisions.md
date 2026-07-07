# 1. Record architecture decisions

- Status: accepted
- Date: 2026-07-07

## Context

We want a durable, low-ceremony record of *why* the project is built the way it is,
so future contributors (and future us) don't re-litigate settled choices.

## Decision

We keep Architecture Decision Records (ADRs) as one Markdown file per decision in
`docs/`, numbered sequentially (`NNNN-title.md`), using a light
[Nygard-style](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions)
format: Context, Decision, Consequences. ADRs are immutable once accepted; a
reversed decision gets a new ADR that supersedes the old one.

## Consequences

- Non-obvious technical choices get a short written rationale at the time they're made.
- The `docs/` directory is the first place to look when a design seems surprising.

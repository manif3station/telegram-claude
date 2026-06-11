# `EPIC-383` Replicate `telegram-codex` As A `telegram-claude` Skill

## Goal

Deliver a new isolated `telegram-claude` skill that replicates the
`telegram-codex` Telegram bridge runtime but drives the Claude Code CLI
(`claude`) instead of the Codex CLI, keeping the collector-owned polling model,
pairing security, live tmux session sharing, media handling, audit trail, and
the Docker noVNC E2E lab.

## Why

`telegram-codex` lets a Telegram chat drive one active Codex session through a
Developer Dashboard collector. The same workflow is valuable for Claude Code
users: bridge a Telegram chat to an active `claude` session so work can be
driven and observed from Telegram while Dashboard owns the polling lifecycle.
Rather than fork behavior into one skill, this epic produces a sibling skill
with the proven runtime contract retargeted to the Claude Code CLI.

## Ticket

1. `DD-383` Port the telegram-codex runtime to a Claude Code CLI bridge.

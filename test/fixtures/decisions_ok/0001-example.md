---
title: Consolidate the REST API on AshJsonApi
status: accepted
date: 2026-06-15
---

# 1. Consolidate the REST API on AshJsonApi

## Status

Accepted.

## Context

This body prose is hand-written and is deliberately **never** read into the
generated architecture artifact — only the front-matter above is indexed.

## Decision

Generate the REST surface (routes and OpenAPI) from Ash resource actions.

## Consequences

The hand-maintained API contract shrinks toward the generated spec.

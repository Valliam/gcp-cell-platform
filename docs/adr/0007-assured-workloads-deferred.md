# 0007 — Org policy now, Assured Workloads behind a flag

**Status:** accepted

## Context

An Australian regulated venture needs data residency. GCP offers two mechanisms
that are often conflated:

**`constraints/gcp.resourceLocations`** — an org policy that refuses to create
resources outside the allowed locations. Free, immediate, applies to everything
under the folder including cells that do not exist yet.

**Assured Workloads** — a compliance regime that additionally constrains Google's
own personnel: support access, data processing and key access stay within the
jurisdiction. It creates and owns its own folder, requires an appropriate
support level, and costs money.

The first is a technical control on *us*. The second is a contractual and
technical control on *Google*. Only the second satisfies a regulator who asks
where Google's support engineers are located.

## Decision

`gcp.resourceLocations` is applied unconditionally, per venture folder, from the
`data_residency.allowed_locations` list in `venture.yaml`. It is always on.

Assured Workloads is implemented in `stacks/org` behind
`data_residency.assured_workloads`, and is `false` for every venture here.

## Consequences

- Residency has a real, enforced control from day one, at no cost, that a cell
  cannot opt out of. Together with the check in `scripts/validate_cells.py` —
  which rejects a contract naming a region outside the envelope, including the
  DR standby region — there are two independent gates before a resource can be
  created in the wrong place.
- Enabling Assured Workloads later is a **migration, not a flag flip**. It
  creates its own folder, and covered projects must live inside it. Moving an
  existing cell means moving a project between folders, which changes inherited
  policy and IAM. This is written down here so that nobody discovers it during a
  compliance deadline.
- The compliance regime enum is a variable
  (`var.assured_workloads_regime`) rather than a literal, because the exact
  value is provider-version specific and should be confirmed against the pinned
  provider before a venture opts in.

## Why not enable it here

This repository is a reference implementation with no billing account and no
support contract behind it. Enabling a paid compliance regime to make a sample
look complete would be dishonest about what has been exercised. The gap is
documented instead, which is what the control would need in a real audit
anyway.

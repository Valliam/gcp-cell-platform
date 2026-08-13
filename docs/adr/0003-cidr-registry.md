# 0003 — Non-overlapping CIDRs across all cells, enforced in CI

**Status:** accepted

## Context

Cells have separate VPCs and, by design, do not talk to each other. Overlapping
address space would therefore be harmless — right up until the first time it
isn't: a shared services VPC, a partner interconnect, a migration that peers two
cells, a VPN back to a corporate network. At that point renumbering a live cell
means recreating its subnet, its cluster and its database.

Renumbering is expensive forever. Allocating carefully is free once.

## Decision

Every cell declares four ranges in its contract, and no two cells anywhere may
overlap on any of them. `scripts/validate_cells.py` checks this across the whole
registry on every pull request.

Current allocation:

| Range | Purpose |
|---|---|
| `10.20.0.0/20` … | node subnets, one /20 per cell |
| `10.x.16.0/20` | pod secondary range |
| `10.x.32.0/22` | service secondary range |
| `172.16.x.0/28` | GKE control plane (Google-managed VPC) |

Cells are numbered by venture: acme takes `10.2x`, globex takes `10.4x`.

## Consequences

- Any two cells can be peered later without touching either.
- The check is arithmetic over the registry, not a wiki page. A wiki page
  recording IP allocations is always out of date; a CI failure is not.
- The `/28` control plane range is a Google requirement, not a choice, and it
  must also avoid overlap — a cluster whose master range collides with a peered
  network fails in ways that are hard to read.

The `/20` per cell caps a cell at roughly 4,000 node addresses and 4,000 pod
addresses, which is far more than the node pool ceilings in any current
contract. If a cell ever needs more, it gets a second range rather than a wider
one, because widening means renumbering.

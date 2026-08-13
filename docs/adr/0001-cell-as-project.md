# 0001 — The cell is a project, not a namespace

**Status:** accepted

## Context

A cell needs an isolation boundary. The candidates, weakest to strongest:
a Kubernetes namespace, a dedicated cluster, a dedicated GCP project, a
dedicated organization.

Namespaces are cheap and were tempting. They also share a control plane, a node
pool, a VPC, a set of IAM bindings and a billing line. Every one of those is a
path by which one tenant's incident becomes another's.

## Decision

One cell = one GCP project.

## Consequences

What this buys:

- **IAM is genuinely separate.** There is no role that grants access to two
  cells at once, so there is no credential whose compromise spans them.
- **Cost is attributable without effort.** A per-project budget answers "which
  cell got expensive" without a billing export or a labelling convention that
  someone will eventually forget.
- **Quota is per-cell.** One venture exhausting a regional CPU quota does not
  stall another venture's deploy.
- **Deletion is clean.** Removing a cell is deleting a project. There is no
  archaeology to work out which resources belonged to it.
- **VPC Service Controls has something to enclose.** Perimeters take projects.
  A namespace cannot be inside a perimeter.

What it costs:

- A fixed per-cell floor: a GKE control plane, Cloud NAT, and the standby
  database. Roughly AUD 400–600/month for a prod cell before workload. Dev cells
  are deliberately shaped differently (zonal database, one NAT IP, no standby)
  to keep that floor low.
- More projects to create, and project creation is slow and quota-limited. The
  first apply of a cell takes 20–30 minutes.
- Anything genuinely shared — the container registry, the audit archive — needs
  an explicit home and explicit cross-project IAM. That is more work than
  sharing by default, and it is the work that makes the sharing auditable.

## Alternatives rejected

**One organization per cell.** Stronger still, and unworkable: org policies,
Cloud Identity and billing all become per-cell administration, and there is no
hierarchy left to inherit guardrails from.

**One cluster per cell inside a shared project.** Isolates the control plane but
not IAM, quota or billing, which are the boundaries that actually get crossed
during an incident.

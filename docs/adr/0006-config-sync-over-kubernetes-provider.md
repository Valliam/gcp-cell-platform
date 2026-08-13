# 0006 — Config Sync, not the Terraform Kubernetes provider

**Status:** accepted

## Context

Each cell needs Kubernetes objects that are part of the platform rather than the
application: a namespace with Pod Security Admission labels, a ResourceQuota
matching the contract, a default-deny NetworkPolicy, and the service account
that Workload Identity binds to.

Terraform can create these with the `kubernetes` provider. Doing so means
configuring that provider from the output of a `google_container_cluster`
resource in the same apply.

## Decision

Terraform stops at the cluster boundary. Kubernetes objects are rendered into
`platform/cells/<venture>/<cell>/` by `scripts/render_platform.py` and delivered
by **Config Sync**, enabled through the fleet.

## Consequences

Why not the Kubernetes provider:

- **Provider configuration from resource output is a known trap.** Terraform
  evaluates provider configuration before it knows the cluster's endpoint on the
  first apply, and after the cluster is destroyed on a teardown. The failure
  modes are obscure ("Get http://localhost/api…") and land at the worst moments.
- **It couples cadence.** A quota change would require a full cell plan against
  cloud APIs. Under Config Sync it is a commit that lands in seconds.
- **Terraform drift-corrects on a schedule; Config Sync does it continuously.**
  A NetworkPolicy deleted by hand comes back in under a minute, not at the next
  nightly plan.

Why generate rather than hand-write the manifests:

- The quota numbers come from the cell contract, so the contract stays the
  single source of truth. Config Sync does not template, so the rendering has to
  happen somewhere; doing it in a script and committing the result keeps
  Config Sync's "what is in git is what is in the cluster" property intact.
- `make render-check` fails CI if the committed manifests do not match the
  contracts, so the generated tree cannot silently rot.

Costs:

- Generated files are committed, which some reviewers dislike. The alternative —
  a templating layer inside the cluster — trades a readable diff for a runtime
  dependency, and the diff is what makes a quota change reviewable.
- Two delivery mechanisms to understand instead of one. The boundary is crisp
  enough to state in a sentence: Terraform owns the cloud, Config Sync owns the
  cluster.

# 0004 — GKE Standard over Autopilot

**Status:** accepted

## Context

Autopilot removes node management: no node pools, no machine types, no
autoscaling configuration, no node upgrades to schedule. For most teams that is
the right default, and choosing Standard needs a reason rather than a habit.

## Decision

GKE Standard, with node pools declared explicitly in the cell contract.

## Consequences

The reasons, in order of weight:

1. **Capacity floors are part of the DR posture.** A prod cell declares
   `min_nodes: 3` so that losing a zone leaves a working cluster, and CI rejects
   a prod cell that declares fewer. Under Autopilot capacity is inferred from
   pod requests, so the same guarantee has to be reconstructed out of
   PodDisruptionBudgets and topology spread constraints — expressible, but no
   longer a single reviewable number in the contract.
2. **Machine shape is a cost lever we use.** Prod runs `n2d-standard-4`, dev runs
   `e2-standard-2`. Autopilot prices per pod request and removes that lever.
3. **CMEK on node boot disks.** Standard exposes `boot_disk_kms_key`; under
   Autopilot node disks are not ours to configure.
4. **Sole-tenancy and specialised pools** are foreseeable for a regulated
   venture, and a later migration from Autopilot to Standard is a cluster
   rebuild.

What we give up, and how it is covered:

- Node upgrades: handled by `release_channel` plus surge upgrade settings
  (`max_surge = 1`, `max_unavailable = 0`), in a maintenance window set to
  Monday 00:00 AEST.
- Node security posture: Shielded VM, Secure Boot, integrity monitoring,
  COS_CONTAINERD and `GKE_METADATA` are set explicitly rather than being
  defaults we inherit. That is more configuration to get right, and it is all in
  one module.
- Bin-packing efficiency: Autopilot is generally better at it. The cluster
  autoscaler with `location_policy = BALANCED` is the mitigation, and the budget
  alert is the backstop.

## Note

Dev cells would be a reasonable place to use Autopilot for cost reasons. They
deliberately do not, because a dev cell whose failure modes differ from prod's
stops being a rehearsal — the same reasoning as
[ADR 0002](0002-single-root-module-per-cell.md).

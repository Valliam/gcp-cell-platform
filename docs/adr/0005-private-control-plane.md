# 0005 — No public control plane, and no bastion either

**Status:** accepted

## Context

A private GKE control plane has no public endpoint. That is the posture a
regulated venture wants, and it immediately raises the question everyone asks
next: how does anyone reach it?

The usual answer is a bastion host inside the VPC. A bastion is a long-lived
VM that must be patched, monitored, access-controlled and audited — a new
security-critical component introduced in the name of security.

## Decision

Private control plane (`enable_private_endpoint = true`) in staging and prod,
reached through the **fleet Connect Gateway**. Every cluster is registered as a
fleet membership; operators and CI authenticate to Google, and the gateway
proxies to the control plane.

Dev cells keep a public endpoint restricted by `master_authorized_networks`,
because the feedback loop matters more there than the last increment of
isolation, and CI policy permits it only for `env: dev`.

## Consequences

- No bastion. No SSH keys, no VM to patch, no jump host that becomes the most
  privileged unmonitored machine in the estate.
- Access is IAM, so it is revoked by removing a group membership and it appears
  in Cloud Audit Logs like any other API call. A bastion's SSH session does not.
- Access can be conditioned on device posture through the VPC-SC access level
  (`trusted_admin`: corporate-owned, screen lock, minimum OS). That is the
  zero-trust part — the network location of the operator stops being what grants
  access.
- Combined with `iam.disableServiceAccountKeyCreation` at the org level and
  Workload Identity Federation in CI, there is no exported credential anywhere
  in the platform that reaches a cluster.

Costs and edges:

- Connect Gateway is a dependency on Google's control path. If the fleet API is
  degraded, `kubectl` is degraded — during an incident, which is when you need
  it. The break-glass path in
  [`docs/runbooks/incident-response.md`](../runbooks/incident-response.md)
  covers this: temporarily enabling the public endpoint is a documented,
  audited, time-bound Terraform change, not an improvisation.
- Nodes have no public IPs, so image pulls and any outbound call go through
  Cloud NAT or the restricted VIP. Anything that assumed direct internet access
  from a node will fail, loudly, the first time.

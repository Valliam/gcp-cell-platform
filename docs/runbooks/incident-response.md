# Runbook — incident response

**Audience:** the on-call platform engineer.
For regional database failover specifically, see
[`failover.md`](failover.md).

---

## Severity

| | Definition | Response |
|---|---|---|
| **SEV1** | Prod cell unavailable to users, or a confirmed data breach | Page immediately. Incident commander. Status updates every 15 min. |
| **SEV2** | Degraded prod, or an SLO burning fast enough to exhaust the budget within days | Page. Updates hourly. |
| **SEV3** | Staging broken, prod redundancy reduced (e.g. replica lag over budget) | Business hours. Ticket. |
| **SEV4** | Drift detected, budget threshold crossed, non-urgent policy finding | Backlog. |

A cell that has lost its DR posture but is serving traffic is SEV3, not SEV1.
Say that out loud early — it stops a redundancy problem being treated with the
urgency and the risk appetite of an outage.

---

## First ten minutes

1. **Acknowledge the page**, so a second person is not woken for the same thing.
2. **Name the cell.** Every alert title starts with `[venture-cell]`. Almost
   nothing in this platform is global; if two cells are affected, that itself is
   important information — it points at the org layer, the shared registry, or
   Google.
3. **Check scope.**
   ```bash
   CELL=acme/prod-syd; VENTURE=${CELL%%/*}; NAME=${CELL##*/}
   PROJECT=cp-$VENTURE-$NAME

   gcloud container clusters describe "$NAME" --project "$PROJECT" \
     --region australia-southeast1 --format='value(status,currentNodeCount)'
   gcloud sql instances list --project "$PROJECT"
   ```
4. **Check whether it is us.** The [GCP status page](https://status.cloud.google.com/)
   first, then the drift issues, then recent applies. In that order, because the
   first is free to check and the last takes the longest.
5. **Open a channel and start writing things down.** Timestamps, commands run,
   what you expected, what happened.

---

## Getting access

Steady-state access is `roles/container.developer` for the venture's platform
group, through the fleet Connect Gateway. That is enough to read logs, describe
resources, restart deployments and scale.

```bash
gcloud container fleet memberships get-credentials "$VENTURE-$NAME" --project "$PROJECT"
```

### Break-glass

If you need more — deleting a stuck resource, editing a CRD, cluster-admin — use
the break-glass binding. It is **time-bound by IAM condition** and defaults to an
expiry in the past, so it grants nothing until deliberately opened.

1. Get a second person's agreement in the incident channel. Say what you need
   and why.
2. Open a window by setting the expiry forward and applying:
   ```bash
   make apply CELL=$CELL TF_CLI_ARGS_apply='-var=breakglass_expiry=2026-08-12T06:00:00Z'
   ```
   Choose an expiry **at most two hours out**. The binding stops granting access
   at that instant whether or not anyone remembers to revoke it.
3. Add yourself to the break-glass group named in the cell contract.
4. When done: remove yourself from the group, and revert the expiry variable in
   the same PR that records the incident.

Every privileged human action fires the
`[cell] Human performed a privileged action` alert. That is intentional and it
is not an accusation — it is what makes step 4 verifiable.

### If Connect Gateway itself is unavailable

The private control plane has no public endpoint, so a fleet API outage means no
`kubectl`. The documented escape is a temporary, audited Terraform change:

```bash
make apply CELL=$CELL   # after editing the contract: gke.private_endpoint: false
```

This is a **reviewed change on a branch**, applied by CI, not a console click.
Revert it in the same incident. Leaving a prod control plane public after an
incident is the single most likely way this platform's security posture quietly
degrades.

---

## Common alerts

### `Error budget burning fast`

The 1-hour burn rate exceeded 14.4×, meaning the 28-day budget is being consumed
fast enough to exhaust within days.

1. Look at the uptime check and the ingress logs — is it total or partial?
2. `kubectl -n app get pods` — crash loop, OOM, image pull failure?
3. Recent deploy? Config Sync makes this easy to answer:
   ```bash
   kubectl -n config-management-system logs -l app=reconciler-manager --tail=50
   git log --oneline -10 -- platform/cells/$VENTURE/$NAME
   ```
4. Roll back by reverting the commit. Config Sync reconciles within a minute.

### `Container restart storm`

More than 5 restarts in 15 minutes for one container.

```bash
kubectl -n app describe pod <pod> | sed -n '/Last State/,/Ready/p'
kubectl -n app logs <pod> --previous
```

`OOMKilled` is the usual answer. Note that raising the memory limit may breach
the namespace ResourceQuota — which comes from the cell contract, so raising it
is a PR against `ventures/…/cells/….yaml`, not a `kubectl edit`.

### `Cross-region replica lag exceeds RPO budget`

SEV3. See [`failover.md` → Replica lag](failover.md#replica-lag).

### `Database disk utilisation high`

Autoresize is on, so this is rarely an availability risk and usually a cost or
data-growth signal. Look for an unbounded table or a runaway retention setting
before letting the disk grow.

### Drift issue raised overnight

Not an incident. Read the plan in the issue, work out who changed what — the
audit sink in the security project has the answer:

```bash
gcloud logging read \
  'protoPayload.authenticationInfo.principalEmail!~"gserviceaccount.com$"' \
  --project "$PROJECT" --freshness=2d --limit=20 \
  --format='table(timestamp, protoPayload.authenticationInfo.principalEmail, protoPayload.methodName)'
```

Then either encode the change in the contract and let the pipeline reapply it,
or revert it and record why it was possible at all.

---

## Closing an incident

- Confirm the alert has cleared, not just that the symptom has.
- If Terraform state diverged from reality, reconcile it before closing. A cell
  whose plan is not clean is a cell whose next routine change is dangerous.
- Revert any break-glass expiry and any temporary posture change, in a PR.
- Write the review within two working days. The question that matters is not
  "what broke" but "what made this hard to see, or hard to fix" — those answers
  become alerts, runbook sections and policy rules.
- If the incident revealed a rule that should have been enforced, add it to
  [`policy/cell.rego`](../../policy/cell.rego) with a fixture that proves it
  rejects. That is how this platform gets safer over time rather than merely
  better documented.

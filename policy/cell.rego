# Compliance policy audit for cell contracts.
#
# These rules run in CI on every pull request with no cloud credentials, which
# means a non-compliant cell is rejected before it is ever planned, let alone
# applied. They encode the rules that are *environment-conditional* — things
# that are legitimate in dev and forbidden in prod. Structural rules (schema,
# residency, CIDR overlap) live in scripts/validate_cells.py instead, because
# they are cross-file and Rego is a poor fit for them.
#
#   conftest test --policy policy ventures/**/cells/*.yaml
package main

import rego.v1

is_prod if input.env == "prod"

is_hardened if input.env in ["staging", "prod"]

cell_id := sprintf("%s/%s", [input.venture, input.cell])

# Rego subtlety worth stating plainly, because getting it wrong makes a rule
# silently unreachable: `not x` succeeds when x is *undefined* or *false*, but
# `null` is a defined, non-false value. So `not input.dr.standby_region` does
# NOT fire on `standby_region: null` — exactly the case these rules exist to
# catch.
#
# Each optional field therefore gets a helper rule that is undefined unless the
# field is genuinely present and non-null. `not <helper>` then behaves for both
# an absent key and an explicit null.
#
# This was caught by policy/fixtures/noncompliant-prod.yaml, which is the reason
# the fixture is in CI.

standby_declared if input.dr.standby_region != null

breakglass_declared if input.security.breakglass_group != null

uptime_host_declared if input.observability.uptime_check_host != null

budget_declared if input.budget.monthly_aud != null

# --- Disaster recovery -------------------------------------------------------

deny contains msg if {
	is_prod
	not standby_declared
	msg := sprintf("%s: prod cells must declare dr.standby_region (cross-region DR is not optional in prod)", [cell_id])
}

deny contains msg if {
	is_prod
	input.dr.standby_region == input.region
	msg := sprintf("%s: dr.standby_region must differ from region (got %s for both)", [cell_id, input.region])
}

deny contains msg if {
	is_prod
	input.dr.rpo_minutes > 15
	msg := sprintf("%s: prod RPO target is 15 minutes or better, declared %d", [cell_id, input.dr.rpo_minutes])
}

deny contains msg if {
	is_prod
	input.dr.rto_minutes > 60
	msg := sprintf("%s: prod RTO target is 60 minutes or better, declared %d", [cell_id, input.dr.rto_minutes])
}

deny contains msg if {
	is_prod
	input.database.availability != "REGIONAL"
	msg := sprintf("%s: prod databases must be REGIONAL (synchronous standby), got %s", [cell_id, input.database.availability])
}

# --- Encryption --------------------------------------------------------------

deny contains msg if {
	is_hardened
	not input.security.cmek
	msg := sprintf("%s: customer-managed encryption keys are mandatory from staging up", [cell_id])
}

# --- Network exposure --------------------------------------------------------

deny contains msg if {
	is_hardened
	not input.gke.private_endpoint
	msg := sprintf("%s: the GKE control plane must be private outside dev (reach it via IAP)", [cell_id])
}

deny contains msg if {
	is_prod
	not input.security.vpc_service_perimeter
	msg := sprintf("%s: prod cells must sit inside a VPC Service Controls perimeter", [cell_id])
}

# --- Capacity and availability -----------------------------------------------

deny contains msg if {
	is_prod
	some pool in input.gke.node_pools
	pool.min_nodes < 3
	msg := sprintf("%s: prod node pool %q has min_nodes=%d; 3 is the floor so a zone loss is survivable", [cell_id, pool.name, pool.min_nodes])
}

deny contains msg if {
	is_prod
	some pool in input.gke.node_pools
	pool.max_nodes <= pool.min_nodes
	msg := sprintf("%s: prod node pool %q cannot scale (max_nodes %d <= min_nodes %d)", [cell_id, pool.name, pool.max_nodes, pool.min_nodes])
}

deny contains msg if {
	count(input.gke.quotas) == 0
	msg := sprintf("%s: every cell must declare resource quotas; an unbounded namespace is a cost incident waiting to happen", [cell_id])
}

# --- Incident response -------------------------------------------------------

deny contains msg if {
	is_prod
	not breakglass_declared
	msg := sprintf("%s: prod cells must nominate a break-glass group for incident access", [cell_id])
}

deny contains msg if {
	is_prod
	not "platform-oncall" in input.observability.notification_channels
	msg := sprintf("%s: prod alerts must route to platform-oncall", [cell_id])
}

deny contains msg if {
	is_prod
	not uptime_host_declared
	msg := sprintf("%s: prod cells must declare an uptime check host", [cell_id])
}

# --- Cost --------------------------------------------------------------------

deny contains msg if {
	not budget_declared
	msg := sprintf("%s: every cell must declare a budget; unbudgeted infrastructure is how ventures bleed", [cell_id])
}

warn contains msg if {
	is_prod
	not 0.5 in input.budget.alert_thresholds
	msg := sprintf("%s: prod budgets should alert at 50%% so overruns are caught mid-month, not after", [cell_id])
}

# --- Release hygiene ---------------------------------------------------------

warn contains msg if {
	is_prod
	input.gke.release_channel == "RAPID"
	msg := sprintf("%s: RAPID channel in prod means unvetted GKE upgrades; prefer REGULAR or STABLE", [cell_id])
}

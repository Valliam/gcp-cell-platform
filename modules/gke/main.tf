# Regional, private, VPC-native GKE cluster with Workload Identity.
#
# Deliberately GKE Standard rather than Autopilot: the cell contract exposes
# node pools, machine types and scaling floors, and Autopilot takes those away.
# See docs/adr/0004.

locals {
  # Node pools are keyed by name so that adding, removing or reordering a pool
  # in the cell contract never forces the replacement of an unrelated pool.
  node_pools = { for p in var.node_pools : p.name => p }
}

resource "google_container_cluster" "this" {
  # checkov:skip=CKV_GCP_66:Binary Authorization is a known, documented gap — see README "What is deliberately not here". The registry enforces immutable tags and scans on push, but admission-time signature verification needs an attestor and a signing key in the build pipeline, which lives outside this repository. Closing it is tracked, not forgotten.
  provider = google-beta

  project  = var.project_id
  name     = var.name
  location = var.region # regional: control plane replicated across three zones

  # The default pool exists only long enough to create the cluster; every real
  # pool is a separate resource so it can be replaced without touching the
  # control plane.
  remove_default_node_pool = true
  initial_node_count       = 1

  deletion_protection = var.deletion_protection

  network    = var.network_id
  subnetwork = var.subnetwork_id

  resource_labels = var.labels

  # Client certificate authentication is a static credential that cannot be
  # revoked without recreating the cluster. Off explicitly rather than by
  # relying on the current default.
  master_auth {
    client_certificate_config {
      issue_client_certificate = false
    }
  }

  # Makes pod-to-pod traffic between nodes visible to VPC flow logs. Without it
  # intra-node traffic is invisible, which is the traffic an attacker moving
  # laterally inside the cluster would generate.
  enable_intranode_visibility = true

  # Binds Kubernetes RBAC to Google Groups, so cluster access is granted by
  # group membership and revoked by removing someone from a group — no
  # per-cluster RoleBinding to chase during offboarding.
  dynamic "authenticator_groups_config" {
    for_each = var.rbac_security_group == null ? [] : [1]
    content {
      security_group = var.rbac_security_group
    }
  }

  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  private_cluster_config {
    # Nodes never get external IPs.
    enable_private_nodes = true

    # A private control plane has no public endpoint at all. Operators and CI
    # reach it through the fleet Connect Gateway, so there is no bastion host to
    # patch and no allowlist to maintain. Dev cells set this false to keep the
    # feedback loop short.
    enable_private_endpoint = var.enable_private_endpoint

    master_ipv4_cidr_block = var.master_cidr

    master_global_access_config {
      enabled = false
    }
  }

  dynamic "master_authorized_networks_config" {
    for_each = length(var.master_authorized_networks) > 0 ? [1] : []
    content {
      dynamic "cidr_blocks" {
        for_each = var.master_authorized_networks
        content {
          cidr_block   = cidr_blocks.value.cidr_block
          display_name = cidr_blocks.value.display_name
        }
      }
    }
  }

  # Workload Identity Federation for GKE: pods assume Google service accounts
  # through their Kubernetes service account. No exported keys anywhere in the
  # cell.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Dataplane V2 (eBPF). Enforces NetworkPolicy natively and emits network
  # policy logs, which is what makes a default-deny posture debuggable rather
  # than merely aspirational. Note: with ADVANCED_DATAPATH the legacy
  # `network_policy` block must be left unset — setting both is a conflict.
  datapath_provider = "ADVANCED_DATAPATH"

  release_channel {
    channel = var.release_channel
  }

  # etcd application-layer secrets encryption with our own key. Without this,
  # Kubernetes Secrets are encrypted only with Google-managed keys.
  database_encryption {
    state    = var.etcd_kms_key == null ? "DECRYPTED" : "ENCRYPTED"
    key_name = var.etcd_kms_key
  }

  monitoring_config {
    enable_components = [
      "SYSTEM_COMPONENTS",
      "APISERVER",
      "CONTROLLER_MANAGER",
      "SCHEDULER",
      "STORAGE",
      "HPA",
      "POD",
      "DAEMONSET",
      "DEPLOYMENT",
      "STATEFULSET",
    ]

    # Google Managed Prometheus. Workloads keep exporting Prometheus metrics and
    # keep being queried with PromQL; we stop running and scaling a Prometheus.
    managed_prometheus {
      enabled = true
    }
  }

  logging_config {
    enable_components = [
      "SYSTEM_COMPONENTS",
      "WORKLOADS",
      "APISERVER",
      "CONTROLLER_MANAGER",
      "SCHEDULER",
    ]
  }

  # Vulnerability scanning of running workloads plus config auditing, surfaced
  # in Security Command Center.
  security_posture_config {
    mode               = "BASIC"
    vulnerability_mode = "VULNERABILITY_BASIC"
  }

  cost_management_config {
    enabled = true
  }

  # Sunday 14:00 UTC is midnight Monday AEST — the lowest-traffic window for an
  # Australian venture, and outside business hours for the on-call who might
  # have to look at it.
  maintenance_policy {
    recurring_window {
      start_time = "2026-01-04T14:00:00Z"
      end_time   = "2026-01-04T22:00:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=SU"
    }
  }

  addons_config {
    horizontal_pod_autoscaling {
      disabled = false
    }
    http_load_balancing {
      disabled = false
    }
    gcs_fuse_csi_driver_config {
      enabled = false
    }
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }
  }

  # Kubernetes API objects (namespaces, quotas, network policies) are delivered
  # by Config Sync, not by a Terraform Kubernetes provider — see docs/adr/0006.
  lifecycle {
    ignore_changes = [
      # The autoscaler owns node counts; Terraform owns the bounds.
      initial_node_count,
    ]
  }
}

resource "google_container_node_pool" "this" {
  provider = google-beta
  for_each = local.node_pools

  project  = var.project_id
  name     = each.key
  cluster  = google_container_cluster.this.id
  location = var.region

  # total_* rather than per-zone counts: the cell contract declares a
  # cluster-wide floor and ceiling, and a reader should not have to multiply by
  # the zone count to know what they are getting.
  autoscaling {
    total_min_node_count = each.value.min_nodes
    total_max_node_count = each.value.max_nodes
    location_policy      = "BALANCED"
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  # Surge upgrades: add a node, drain an old one, never dip below capacity.
  upgrade_settings {
    strategy        = "SURGE"
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type = each.value.machine_type
    disk_size_gb = each.value.disk_size_gb
    disk_type    = "pd-balanced"
    image_type   = "COS_CONTAINERD"

    # Dedicated least-privilege identity, not the default compute SA.
    service_account = var.node_service_account
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    # Forces pods to use Workload Identity: the legacy metadata endpoints that
    # would hand out the node's own credentials are not reachable.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    boot_disk_kms_key = var.boot_disk_kms_key

    labels = merge(var.labels, {
      pool = each.key
    })

    tags = ["gke-node", var.name]

    metadata = {
      disable-legacy-endpoints = "true"
    }
  }

  lifecycle {
    # A node pool cannot be updated in place for most node_config changes; it is
    # replaced. create_before_destroy keeps capacity available through that.
    create_before_destroy = true
  }
}

# --- Fleet registration and Config Sync ---------------------------------------
# Registering the cluster into a fleet gives two things at once: Connect Gateway
# access to a control plane with no public endpoint, and Config Sync to deliver
# the Kubernetes baseline (namespaces, ResourceQuota, default-deny
# NetworkPolicy) from git.

resource "google_gke_hub_membership" "this" {
  provider = google-beta

  project       = var.project_id
  membership_id = var.name
  location      = "global"

  endpoint {
    gke_cluster {
      resource_link = "//container.googleapis.com/${google_container_cluster.this.id}"
    }
  }
}

resource "google_gke_hub_feature" "configmanagement" {
  provider = google-beta

  project  = var.project_id
  name     = "configmanagement"
  location = "global"
}

resource "google_gke_hub_feature_membership" "this" {
  provider = google-beta

  project    = var.project_id
  location   = "global"
  feature    = google_gke_hub_feature.configmanagement.name
  membership = google_gke_hub_membership.this.membership_id

  configmanagement {
    config_sync {
      enabled = true
      git {
        sync_repo   = var.config_sync.repo
        sync_branch = var.config_sync.branch
        # Each cell syncs its own overlay plus the shared baseline, so a quota
        # change lands as a reviewed commit rather than a kubectl apply.
        policy_dir  = var.config_sync.policy_dir
        secret_type = "none" # public repo; a private repo would use gcpserviceaccount
      }
      source_format = "unstructured"
    }
  }
}

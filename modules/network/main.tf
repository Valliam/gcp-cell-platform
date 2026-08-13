# One VPC per cell. GCP VPCs are global, which is what makes the Sydney →
# Melbourne DR topology cheap: the standby region attaches to the same VPC and
# the same Private Service Access range, with no peering and no second network
# to keep in sync.

resource "google_compute_network" "this" {
  project                 = var.project_id
  name                    = var.name
  auto_create_subnetworks = false
  routing_mode            = "GLOBAL"
  description             = "Cell VPC for ${var.name}"
}

resource "google_compute_subnetwork" "primary" {
  project = var.project_id
  name    = "${var.name}-${var.region}"
  region  = var.region
  network = google_compute_network.this.id

  ip_cidr_range = var.subnet_cidr

  # Nodes have no external IPs, so every Google API call has to resolve
  # somewhere private. Private Google Access is what makes that work.
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = var.flow_log_sampling
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# --- Egress ------------------------------------------------------------------
# Nodes are private. Outbound internet (image pulls from third-party registries,
# webhook callbacks) goes through Cloud NAT, which gives a stable, auditable
# egress IP set and no inbound surface at all.

resource "google_compute_router" "this" {
  project = var.project_id
  name    = "${var.name}-router"
  region  = var.region
  network = google_compute_network.this.id
}

resource "google_compute_address" "nat" {
  count = var.nat_ip_count

  project = var.project_id
  name    = "${var.name}-nat-${count.index}"
  region  = var.region
}

resource "google_compute_router_nat" "this" {
  project = var.project_id
  name    = "${var.name}-nat"
  router  = google_compute_router.this.name
  region  = var.region

  # Static IPs, not auto-allocated: partners allowlist our egress, and an IP
  # that changes on every apply is an outage waiting to happen.
  nat_ip_allocate_option = "MANUAL_ONLY"
  nat_ips                = google_compute_address.nat[*].self_link

  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# --- Private Service Access ---------------------------------------------------
# Cloud SQL instances live in a Google-managed tenant VPC peered to ours. This
# reserved range is where their private IPs come from. It is global, so the
# Melbourne replica draws from the same allocation.

resource "google_compute_global_address" "psa" {
  project       = var.project_id
  name          = "${var.name}-psa"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 20
  network       = google_compute_network.this.id
}

resource "google_service_networking_connection" "psa" {
  network                 = google_compute_network.this.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa.name]

  # Without this, `terraform destroy` leaves the peering behind and the next
  # apply of a same-named cell fails on a range that is still in use.
  deletion_policy = "ABANDON"
}

# --- Private access to Google APIs -------------------------------------------
# Inside a VPC Service Controls perimeter, traffic must reach Google APIs via
# the restricted VIP (199.36.153.4/30). Anything hitting the public endpoints is
# outside the perimeter and gets denied. These two records are what make that
# transparent to workloads.

resource "google_dns_managed_zone" "googleapis" {
  project     = var.project_id
  name        = "${var.name}-googleapis"
  dns_name    = "googleapis.com."
  description = "Route Google API traffic to the VPC-SC restricted VIP"
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.this.id
    }
  }
}

resource "google_dns_record_set" "restricted_a" {
  project      = var.project_id
  managed_zone = google_dns_managed_zone.googleapis.name
  name         = "restricted.googleapis.com."
  type         = "A"
  ttl          = 300
  rrdatas      = ["199.36.153.4", "199.36.153.5", "199.36.153.6", "199.36.153.7"]
}

resource "google_dns_record_set" "googleapis_cname" {
  project      = var.project_id
  managed_zone = google_dns_managed_zone.googleapis.name
  name         = "*.googleapis.com."
  type         = "CNAME"
  ttl          = 300
  rrdatas      = ["restricted.googleapis.com."]
}

# Artifact Registry is reached at *.pkg.dev, which needs the same treatment or
# every image pull leaves the perimeter.
resource "google_dns_managed_zone" "pkgdev" {
  project     = var.project_id
  name        = "${var.name}-pkgdev"
  dns_name    = "pkg.dev."
  description = "Route Artifact Registry pulls to the restricted VIP"
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.this.id
    }
  }
}

resource "google_dns_record_set" "pkgdev_cname" {
  project      = var.project_id
  managed_zone = google_dns_managed_zone.pkgdev.name
  name         = "*.pkg.dev."
  type         = "CNAME"
  ttl          = 300
  rrdatas      = ["restricted.googleapis.com."]
}

resource "google_compute_route" "restricted_vip" {
  project          = var.project_id
  name             = "${var.name}-restricted-vip"
  network          = google_compute_network.this.id
  dest_range       = "199.36.153.4/30"
  next_hop_gateway = "default-internet-gateway"
  priority         = 100
  description      = "Reach the restricted VIP without traversing Cloud NAT"
}

# --- Firewall ----------------------------------------------------------------
# GCP denies ingress by default, but the implied rule is invisible in audits.
# An explicit low-priority deny with logging makes rejected traffic observable,
# which is the difference between "we think nothing is probing us" and knowing.

resource "google_compute_firewall" "deny_all_ingress" {
  project     = var.project_id
  name        = "${var.name}-deny-all-ingress"
  network     = google_compute_network.this.name
  direction   = "INGRESS"
  priority    = 65000
  description = "Explicit catch-all deny so denied ingress is logged"

  deny {
    protocol = "all"
  }

  source_ranges = ["0.0.0.0/0"]

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_firewall" "allow_internal" {
  project   = var.project_id
  name      = "${var.name}-allow-internal"
  network   = google_compute_network.this.name
  direction = "INGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = [var.subnet_cidr, var.pods_cidr, var.services_cidr]
}

# The GKE control plane lives in a Google-managed VPC and needs to reach
# admission and conversion webhooks running on nodes. Omitting this is the usual
# cause of "context deadline exceeded" on webhook calls in a private cluster.
resource "google_compute_firewall" "allow_master_webhooks" {
  project     = var.project_id
  name        = "${var.name}-allow-master-webhooks"
  network     = google_compute_network.this.name
  direction   = "INGRESS"
  priority    = 1000
  description = "GKE control plane to node webhook ports"

  allow {
    protocol = "tcp"
    ports    = ["443", "8443", "9443", "15017"]
  }

  source_ranges = [var.master_cidr]
  target_tags   = ["gke-node"]
}

resource "google_compute_firewall" "allow_health_checks" {
  project     = var.project_id
  name        = "${var.name}-allow-health-checks"
  network     = google_compute_network.this.name
  direction   = "INGRESS"
  priority    = 1000
  description = "Google load balancer health check ranges"

  allow {
    protocol = "tcp"
  }

  # Fixed, documented Google-owned ranges — not arbitrary internet.
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags   = ["gke-node"]
}

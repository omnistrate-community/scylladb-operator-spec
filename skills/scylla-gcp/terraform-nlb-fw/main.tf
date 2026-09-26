terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0.0"
    }
  }
}

# Filled in by the ScyllaDB spec from the deployment cell.
variable "projectId" {
  type = string
}

# The cell's VPC (name or self link).
variable "network" {
  type = string
}

# Network tag Omnistrate puts on every node of this plan's node pools
# (product-tier-<plan id>-id); in this plan only the ScyllaDB members have nodes.
variable "planTag" {
  type = string
}

provider "google" {
  project = var.projectId
}

# Every range inside the cell: node subnets and their secondary (pod/service) ranges.
data "google_compute_network" "cell" {
  name = basename(var.network)
}

data "google_compute_subnetwork" "cell" {
  for_each  = toset(data.google_compute_network.cell.subnetworks_self_links)
  self_link = each.value
}

locals {
  cell_ranges = distinct(flatten([
    for sn in data.google_compute_subnetwork.cell :
    concat([sn.ip_cidr_range], [for r in sn.secondary_ip_range : r.ip_cidr_range])
  ]))
  # Every port on the operator's member Services except client CQL (9042),
  # shard-aware CQL (19042) and the token-authenticated Manager agent (10001).
  internal_ports = ["7000", "7001", "7199", "9142", "19142", "9180", "5090", "9100", "9160"]
}

# GKE opens every port of a LoadBalancer Service to the internet (its k8s2-*
# rules, priority 1000). These two rules take precedence on the ScyllaDB
# nodes: the internal ports stay reachable from inside the cell...
resource "google_compute_firewall" "internal_allow" {
  name          = "scylla-int-allow-{{ $sys.id }}"
  network       = data.google_compute_network.cell.self_link
  priority      = 900
  direction     = "INGRESS"
  source_ranges = local.cell_ranges
  target_tags   = [var.planTag]
  allow {
    protocol = "tcp"
    ports    = local.internal_ports
  }
}

# ...and closed to everything else.
resource "google_compute_firewall" "public_deny" {
  name          = "scylla-int-deny-{{ $sys.id }}"
  network       = data.google_compute_network.cell.self_link
  priority      = 950
  direction     = "INGRESS"
  source_ranges = ["0.0.0.0/0"]
  target_tags   = [var.planTag]
  deny {
    protocol = "tcp"
    ports    = local.internal_ports
  }
}

output "firewallName" {
  value = google_compute_firewall.public_deny.name
}

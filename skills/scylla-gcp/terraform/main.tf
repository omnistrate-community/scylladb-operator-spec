terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0.0"
    }
  }
}

variable "projectId" {
  type = string
}

variable "bucketLocation" {
  type    = string
  default = "us-central1"
}

provider "google" {
  project = var.projectId
}

locals {
  # One bucket (and service account) per gcs-bucket instance; $sys.id is its
  # instance id. Service-account ids are limited to 30 chars.
  id      = replace("{{ $sys.id }}", "instance-", "")
  name    = "scylla-backup-${local.id}"
  sa_name = "scylla-bk-${local.id}"
}

resource "google_storage_bucket" "backup" {
  name                        = local.name
  location                    = var.bucketLocation
  force_destroy               = true
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # No versioning: Scylla Manager purges snapshots by deleting objects, and
  # noncurrent versions would keep every deleted SSTable billable.
  lifecycle_rule {
    condition {
      age = 7
    }
    action {
      type = "AbortIncompleteMultipartUpload"
    }
  }

  labels = {
    "omnistrate-managed-by" = "omnistrate"
    "scylla-purpose"        = "scylla-backup"
  }
}

# Least-privilege identity for the Scylla Manager agent (rclone): object read/write/delete plus
# bucket metadata reads on this one bucket.
resource "google_service_account" "backup" {
  account_id   = local.sa_name
  display_name = "ScyllaDB backups for ${local.name}"
}

resource "google_storage_bucket_iam_member" "object_admin" {
  bucket = google_storage_bucket.backup.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.backup.email}"
}

resource "google_storage_bucket_iam_member" "bucket_reader" {
  bucket = google_storage_bucket.backup.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.backup.email}"
}

resource "google_service_account_key" "backup" {
  service_account_id = google_service_account.backup.name
}

output "bucketName" {
  value = google_storage_bucket.backup.name
}

output "bucketLocation" {
  value = google_storage_bucket.backup.location
}

# Already base64-encoded JSON; the ScyllaDB spec writes it into a Secret's
# `data` field as-is.
output "credentialsBase64" {
  value     = google_service_account_key.backup.private_key
  sensitive = true
}

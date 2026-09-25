terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0"
    }
  }
}

# Bucket region comes from the bucketRegion API param (default us-east-1).
variable "bucketRegion" {
  type    = string
  default = "us-east-1"
}

provider "aws" {
  region = var.bucketRegion
}

locals {
  # One bucket (and IAM user) per s3-bucket instance; $sys.id is its instance id.
  name = "scylla-backup-{{ $sys.id }}"
}

# No versioning: Scylla Manager purges snapshots by deleting objects, and
# noncurrent versions would keep every deleted SSTable billable.
resource "aws_s3_bucket" "backup" {
  bucket        = local.name
  force_destroy = true
  tags = {
    "omnistrate.com/managed-by" = "omnistrate"
    "scylla/purpose"            = "scylla-backup"
  }
}

resource "aws_s3_bucket_public_access_block" "backup" {
  bucket                  = aws_s3_bucket.backup.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Abandoned multipart uploads (e.g. an interrupted backup) are otherwise billed forever.
resource "aws_s3_bucket_lifecycle_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id
  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Least-privilege IAM user scoped to this one bucket — the Scylla Manager
# agent (rclone) needs list/read/write/delete plus the multipart actions.
resource "aws_iam_user" "backup" {
  name = local.name
  tags = {
    "omnistrate.com/managed-by" = "omnistrate"
  }
}

resource "aws_iam_user_policy" "backup" {
  name = "backup-readwrite"
  user = aws_iam_user.backup.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"]
        Resource = aws_s3_bucket.backup.arn
      },
      {
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject",
        "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
        Resource = "${aws_s3_bucket.backup.arn}/*"
      }
    ]
  })
}

resource "aws_iam_access_key" "backup" {
  user = aws_iam_user.backup.name
}

output "bucketName" {
  value = aws_s3_bucket.backup.bucket
}

output "bucketRegion" {
  value = var.bucketRegion
}

output "accessKeyId" {
  value = aws_iam_access_key.backup.id
}

output "secretAccessKey" {
  value     = aws_iam_access_key.backup.secret
  sensitive = true
}

locals {
  bucket_key_enabled                 = var.kms_key_arn != null ? true : false
  cors_rule                          = var.cors_rule != null ? { create = true } : {}
  lifecycle_rules                    = try(jsondecode(var.lifecycle_rule), var.lifecycle_rule)
  logging                            = try(var.logging.target_bucket != null, false) ? { create = true } : {}
  logging_permissions                = length(local.logging_permissions_source_buckets) > 0 ? { create = true } : {}
  logging_permissions_source_buckets = try(var.logging.target_bucket == var.name, false) ? compact(concat(["arn:aws:s3:::${var.name}"], var.logging_source_bucket_arns)) : var.logging_source_bucket_arns
  object_lock_configuration          = var.object_lock_mode != null ? { create : true } : {}
  policy                             = var.policy != null ? var.policy : null
}

data "aws_iam_policy_document" "ssl_policy" {
  statement {
    sid     = "AllowSSLRequestsOnly"
    actions = ["s3:*"]
    effect  = "Deny"
    resources = [
      "arn:aws:s3:::${var.name}",
      "arn:aws:s3:::${var.name}/*"
    ]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }
}

data "aws_iam_policy_document" "logging_policy" {
  dynamic "statement" {
    for_each = local.logging_permissions

    content {
      sid     = "S3AccessLog"
      actions = ["s3:PutObject"]
      effect  = "Allow"
      resources = [
        "arn:aws:s3:::${var.name}/*"
      ]
      principals {
        type        = "Service"
        identifiers = ["logging.s3.amazonaws.com"]
      }
      condition {
        test     = "ArnLike"
        variable = "aws:SourceArn"
        values   = local.logging_permissions_source_buckets
      }
    }
  }
}

data "aws_iam_policy_document" "combined" {
  source_policy_documents = compact([
    local.policy,
    data.aws_iam_policy_document.ssl_policy.json,
    data.aws_iam_policy_document.logging_policy.json
  ])
}

resource "aws_s3_bucket" "default" {
  bucket              = var.name
  force_destroy       = var.force_destroy
  object_lock_enabled = var.object_lock_mode != null ? true : false
  tags                = var.tags
}

resource "aws_s3_bucket_acl" "default" {
  count  = var.object_ownership_type == "ObjectWriter" ? 1 : 0
  bucket = aws_s3_bucket.default.id
  acl    = var.acl
}

resource "aws_s3_bucket_ownership_controls" "default" {
  bucket = aws_s3_bucket.default.id
  rule {
    object_ownership = var.object_ownership_type
  }
}

resource "aws_s3_bucket_cors_configuration" "default" {
  for_each = local.cors_rule
  bucket   = aws_s3_bucket.default.bucket

  cors_rule {
    allowed_headers = var.cors_rule.allowed_headers
    allowed_methods = var.cors_rule.allowed_methods
    allowed_origins = var.cors_rule.allowed_origins
    expose_headers  = var.cors_rule.expose_headers
    max_age_seconds = var.cors_rule.max_age_seconds
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "default" {
  count = length(local.lifecycle_rules) > 0 ? 1 : 0

  bucket = aws_s3_bucket.default.bucket

  dynamic "rule" {
    for_each = local.lifecycle_rules

    content {
      id     = try(rule.value.id, null)
      status = try(rule.value.status, "Enabled")

      dynamic "filter" {
        for_each = try([rule.value.prefix], [])

        content {
          prefix = try(filter.value, null)
        }
      }

      dynamic "abort_incomplete_multipart_upload" {
        for_each = try(flatten([rule.value.abort_incomplete_multipart_upload]), [])

        content {
          days_after_initiation = try(abort_incomplete_multipart_upload.value.days_after_initiation, null)
        }
      }

      dynamic "expiration" {
        for_each = try(flatten([rule.value.expiration]), [])

        content {
          date                         = try(expiration.value.date, null)
          days                         = try(expiration.value.days, null)
          expired_object_delete_marker = try(expiration.value.expired_object_delete_marker, null)
        }
      }

      dynamic "noncurrent_version_expiration" {
        for_each = try(flatten([rule.value.noncurrent_version_expiration]), [])

        content {
          newer_noncurrent_versions = try(noncurrent_version_expiration.value.newer_noncurrent_versions, null)
          noncurrent_days           = try(noncurrent_version_expiration.value.noncurrent_days, null)
        }
      }

      dynamic "noncurrent_version_transition" {
        for_each = try(flatten([rule.value.noncurrent_version_transition]), [])

        content {
          newer_noncurrent_versions = try(noncurrent_version_transition.value.newer_noncurrent_versions, null)
          noncurrent_days           = try(noncurrent_version_transition.value.noncurrent_days, null)
          storage_class             = noncurrent_version_transition.value.storage_class
        }
      }

      dynamic "transition" {
        for_each = try(flatten([rule.value.transition]), [])

        content {
          date          = try(transition.value.date, null)
          days          = try(transition.value.days, null)
          storage_class = transition.value.storage_class
        }
      }
    }
  }
}

resource "aws_s3_bucket_logging" "default" {
  for_each      = local.logging
  bucket        = aws_s3_bucket.default.id
  target_bucket = var.logging.target_bucket
  target_prefix = var.logging.target_prefix

  lifecycle {
    precondition {
      condition     = var.logging.target_bucket != var.name || var.object_lock_mode == null
      error_message = "You're trying to enable server access logging and object locking on the same bucket! Object lock will prevent server access logs from written to the bucket. Either log to a different bucket or remove the object lock configuration."
    }
  }
}

resource "aws_s3_bucket_object_lock_configuration" "default" {
  for_each = local.object_lock_configuration
  bucket   = aws_s3_bucket.default.bucket

  rule {
    default_retention {
      mode  = var.object_lock_mode
      years = var.object_lock_years
      days  = var.object_lock_days
    }
  }

  lifecycle {
    precondition {
      condition     = var.object_lock_mode == null || length(local.logging_permissions_source_buckets) == 0
      error_message = "You're trying to allow (other buckets) logging to this bucket and enable object locking on the same bucket! Object lock will prevent server access logs from written to the bucket. Either remove the logging source buckets configuration or remove the object lock configuration."
    }
  }
}

resource "aws_s3_bucket_replication_configuration" "default" {
  for_each = var.replication_configuration
  role     = each.value.iam_role_arn
  bucket   = aws_s3_bucket.default.id

  rule {
    id     = each.value.rule_id
    status = "Enabled"

    destination {
      bucket        = each.value.dest_bucket
      storage_class = each.value.dest_storage_class
    }
  }

  depends_on = [aws_s3_bucket_versioning.default]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "default" {
  bucket = aws_s3_bucket.default.bucket

  rule {
    bucket_key_enabled = local.bucket_key_enabled

    apply_server_side_encryption_by_default {
      kms_master_key_id = var.kms_key_arn
      sse_algorithm     = var.kms_key_arn != null ? "aws:kms" : "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "default" {
  bucket = aws_s3_bucket.default.id
  policy = data.aws_iam_policy_document.combined.json
}

resource "aws_s3_bucket_public_access_block" "default" {
  bucket                  = aws_s3_bucket.default.id
  block_public_acls       = var.block_public_acls
  block_public_policy     = var.block_public_policy
  ignore_public_acls      = var.ignore_public_acls
  restrict_public_buckets = var.restrict_public_buckets
}

// tfsec:ignore:aws-s3-enable-versioning
resource "aws_s3_bucket_versioning" "default" {
  #checkov:skip=CKV_AWS_21: Ensure all data stored in the S3 bucket have versioning enabled - consumer of the module should decide
  bucket = aws_s3_bucket.default.id

  versioning_configuration {
    status = var.versioning ? "Enabled" : "Suspended"
  }
}

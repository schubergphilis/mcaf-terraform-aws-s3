locals {
  logging_permissions = length(var.logging_source_bucket_arns) > 0 ? { create = true } : {}
  policy              = var.policy != null ? var.policy : null

  # On/Off switches for optional resources and configuration
  bucket_key_enabled                       = var.kms_key_arn != null ? true : false
  cors_rule_enabled                        = var.cors_rule != null ? { create = true } : {}
  logging_partitioned_prefix_enabled       = try(var.logging.target_object_key_format.format_type, null) == "partitioned" ? { create = true } : {}
  logging_simple_prefix_enabled            = try(var.logging.target_object_key_format.format_type, null) == "simple" ? { create = true } : {}
  logging_target_object_key_format_enabled = try(var.logging.target_object_key_format, null) != null ? { create = true } : {}
  object_lock_enabled                      = var.object_lock_mode != null ? { create : true } : {}
  replication_configuration_enabled        = var.replication_configuration != null ? { create = true } : {}
}

################################################################################
# S3 Bucket & Bucket Policy
################################################################################

resource "aws_s3_bucket" "default" {
  bucket              = var.name
  bucket_prefix       = var.name_prefix
  force_destroy       = var.force_destroy
  object_lock_enabled = var.object_lock_mode != null ? true : false
  tags                = var.tags
}

data "aws_iam_policy_document" "ssl_policy" {
  statement {
    sid     = "AllowSSLRequestsOnly"
    actions = ["s3:*"]
    effect  = "Deny"
    resources = [
      aws_s3_bucket.default.arn,
      "${aws_s3_bucket.default.arn}/*"
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
        "${aws_s3_bucket.default.arn}/*"
      ]
      principals {
        type        = "Service"
        identifiers = ["logging.s3.amazonaws.com"]
      }
      condition {
        test     = "ArnLike"
        variable = "aws:SourceArn"
        values   = var.logging_source_bucket_arns
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

resource "aws_s3_bucket_policy" "default" {
  bucket = aws_s3_bucket.default.id
  policy = data.aws_iam_policy_document.combined.json
}

################################################################################
# S3 Bucket Configuration
################################################################################

###
# Ownership & ACL
###

resource "aws_s3_bucket_ownership_controls" "default" {
  bucket = aws_s3_bucket.default.id

  rule {
    object_ownership = var.object_ownership_type
  }
}

resource "aws_s3_bucket_acl" "default" {
  count = var.object_ownership_type == "ObjectWriter" ? 1 : 0

  bucket = aws_s3_bucket.default.id
  acl    = var.acl

  depends_on = [aws_s3_bucket_ownership_controls.default]
}

###
# CORS
###

resource "aws_s3_bucket_cors_configuration" "default" {
  for_each = local.cors_rule_enabled

  bucket = aws_s3_bucket.default.bucket

  cors_rule {
    allowed_headers = var.cors_rule.allowed_headers
    allowed_methods = var.cors_rule.allowed_methods
    allowed_origins = var.cors_rule.allowed_origins
    expose_headers  = var.cors_rule.expose_headers
    max_age_seconds = var.cors_rule.max_age_seconds
  }
}

###
# Inventory
###

resource "aws_s3_bucket_inventory" "default" {
  for_each = var.inventory_configuration

  bucket                   = aws_s3_bucket.default.id
  enabled                  = each.value.enabled
  included_object_versions = each.value.included_object_versions
  name                     = each.key
  optional_fields          = each.value.optional_fields

  destination {
    bucket {
      account_id = each.value.destination.account_id
      bucket_arn = each.value.destination.bucket_arn
      format     = each.value.destination.format
      prefix     = each.value.destination.prefix

      encryption {
        dynamic "sse_kms" {
          for_each = each.value.destination.encryption.encryption_type == "sse_kms" ? { create = true } : {}

          content {
            key_id = each.value.destination.encryption.kms_key_id
          }
        }

        dynamic "sse_s3" {
          for_each = each.value.destination.encryption.encryption_type == "sse_s3" ? { create = true } : {}

          content {
          }
        }
      }
    }
  }

  schedule {
    frequency = each.value.frequency
  }

  dynamic "filter" {
    for_each = each.value.filter_prefix != null ? { create = true } : {}

    content {
      prefix = each.value.filter_prefix
    }
  }
}

###
# Lifecycle
###

resource "aws_s3_bucket_lifecycle_configuration" "default" {
  count = length(var.lifecycle_rule) > 0 ? 1 : 0

  bucket                                 = aws_s3_bucket.default.bucket
  transition_default_minimum_object_size = var.lifecycle_rule.transition_default_minimum_object_size

  dynamic "rule" {
    for_each = var.lifecycle_rule

    content {
      id     = rule.value.id
      status = rule.value.status ? "Enabled" : "Disabled"

      # --------------------------------------------------------------
      # abort_incomplete_multipart_upload (max 1 block)
      # --------------------------------------------------------------
      dynamic "abort_incomplete_multipart_upload" {
        for_each = rule.value.abort_incomplete_multipart_upload != null ? [rule.value.abort_incomplete_multipart_upload] : []

        content {
          days_after_initiation = abort_incomplete_multipart_upload.value.days_after_initiation
        }
      }

      # ------------
      # expiration (max 1 block)
      # ------------
      dynamic "expiration" {
        for_each = rule.value.expiration != null ? [rule.value.expiration] : []

        content {
          date                         = expiration.value.date
          days                         = expiration.value.days
          expired_object_delete_marker = expiration.value.expired_object_delete_marker
        }
      }

      # --------------------------------------------------
      # filter (max 1 block)
      # --------------------------------------------------
      dynamic "filter" {
        for_each = rule.value.filter != null ? [rule.value.filter] : []

        content {
          prefix                   = filter.value.prefix
          object_size_greater_than = filter.value.object_size_greater_than
          object_size_less_than    = filter.value.object_size_less_than

          dynamic "tag" {
            for_each = filter.value.tag != null ? [filter.value.tag] : []

            content {
              key   = tag.value.key
              value = tag.value.value
            }
          }

          dynamic "and" {
            for_each = filter.value.and != null ? [filter.value.and] : []

            content {
              prefix                   = and.value.prefix
              object_size_greater_than = and.value.object_size_greater_than
              object_size_less_than    = and.value.object_size_less_than
              tags                     = and.value.tags
            }
          }
        }
      }

      # -------------------------------
      # noncurrent_version_expiration (max 1 block)
      # -------------------------------
      dynamic "noncurrent_version_expiration" {
        for_each = rule.value.noncurrent_version_expiration != null ? [rule.value.noncurrent_version_expiration] : []

        content {
          newer_noncurrent_versions = noncurrent_version_expiration.value.newer_noncurrent_versions
          noncurrent_days           = noncurrent_version_expiration.value.noncurrent_days
        }
      }

      # -------------------------------
      # noncurrent_version_transition (1..n blocks)
      # -------------------------------
      dynamic "noncurrent_version_transition" {
        for_each = rule.value.noncurrent_version_transition != null ? rule.value.noncurrent_version_transition : []

        content {
          newer_noncurrent_versions = noncurrent_version_transition.value.newer_noncurrent_versions
          noncurrent_days           = noncurrent_version_transition.value.noncurrent_days
          storage_class             = noncurrent_version_transition.value.storage_class
        }
      }

      # -----------
      # transition (1..n blocks)
      # -----------
      dynamic "transition" {
        for_each = rule.value.transition != null ? rule.value.transition : []

        content {
          date          = transition.value.date
          days          = transition.value.days
          storage_class = transition.value.storage_class
        }
      }
    }
  }
}

###
# Logging
###

resource "aws_s3_bucket_logging" "default" {
  count = var.logging != null ? 1 : 0

  bucket        = aws_s3_bucket.default.id
  target_bucket = var.logging.target_bucket
  target_prefix = var.logging.target_prefix


  dynamic "target_object_key_format" {
    for_each = local.logging_target_object_key_format_enabled

    content {
      dynamic "partitioned_prefix" {
        for_each = local.logging_partitioned_prefix_enabled

        content {
          partition_date_source = var.logging.target_object_key_format.partition_date_source
        }
      }

      dynamic "simple_prefix" {
        for_each = local.logging_simple_prefix_enabled

        content {}
      }
    }
  }

  lifecycle {
    precondition {
      condition     = var.logging.target_bucket != aws_s3_bucket.default.id || var.object_lock_mode == null
      error_message = "You're trying to enable server access logging and object locking on the same bucket! Object lock will prevent server access logs from written to the bucket. Either log to a different bucket or remove the object lock configuration."
    }
  }
}

###
# Object Lock
###

resource "aws_s3_bucket_object_lock_configuration" "default" {
  for_each = local.object_lock_enabled

  bucket = aws_s3_bucket.default.bucket

  rule {
    default_retention {
      mode  = var.object_lock_mode
      years = var.object_lock_years
      days  = var.object_lock_days
    }
  }

  lifecycle {
    precondition {
      condition     = var.object_lock_mode == null || length(var.logging_source_bucket_arns) == 0
      error_message = "You're trying to allow (other buckets) logging to this bucket and enable object locking on the same bucket! Object lock will prevent server access logs from written to the bucket. Either remove the logging source buckets configuration or remove the object lock configuration."
    }
  }
}

###
# Notification / EventBridge
###

resource "aws_s3_bucket_notification" "eventbridge" {
  count = var.eventbridge_enabled ? 1 : 0

  bucket      = aws_s3_bucket.default.id
  eventbridge = var.eventbridge_enabled
}

###
# Replication
###

resource "aws_s3_bucket_replication_configuration" "default" {
  for_each = local.replication_configuration_enabled

  role   = var.replication_configuration.iam_role_arn
  bucket = aws_s3_bucket.default.id

  dynamic "rule" {
    for_each = var.replication_configuration.rules

    content {
      id       = rule.value["id"]
      priority = rule.key
      status   = "Enabled"

      delete_marker_replication {
        status = "Disabled"
      }

      destination {
        bucket        = rule.value["dest_bucket"]
        storage_class = rule.value["dest_storage_class"]

        dynamic "encryption_configuration" {
          for_each = rule.value.replica_kms_key_arn != null ? { create = true } : {}

          content {
            replica_kms_key_id = rule.value.replica_kms_key_arn
          }
        }
      }

      dynamic "source_selection_criteria" {
        for_each = rule.value.source_selection_criteria != null ? { create = true } : {}

        content {
          replica_modifications {
            status = rule.value.source_selection_criteria.replica_modifications ? "Enabled" : "Disabled"
          }
          sse_kms_encrypted_objects {
            status = rule.value.source_selection_criteria.sse_kms_encrypted_objects ? "Enabled" : "Disabled"
          }
        }
      }

      filter {}
    }
  }

  depends_on = [aws_s3_bucket_versioning.default]
}

###
# Server-Side Encryption
###

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

###
# Public Access Block
###

resource "aws_s3_bucket_public_access_block" "default" {
  bucket                  = aws_s3_bucket.default.id
  block_public_acls       = var.block_public_acls
  block_public_policy     = var.block_public_policy
  ignore_public_acls      = var.ignore_public_acls
  restrict_public_buckets = var.restrict_public_buckets
}

###
# Versioning
###

resource "aws_s3_bucket_versioning" "default" {
  bucket = aws_s3_bucket.default.id

  versioning_configuration {
    status = var.versioning ? "Enabled" : "Suspended"
  }
}

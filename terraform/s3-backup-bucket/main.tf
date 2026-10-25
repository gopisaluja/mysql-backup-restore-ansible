data "aws_region" "current" {}

locals {
  create_kms_key = var.kms_key_arn == null
  kms_key_arn    = local.create_kms_key ? aws_kms_key.backups[0].arn : var.kms_key_arn
  prefix         = trim(var.backup_prefix, "/")
  objects_arn    = "${aws_s3_bucket.backups.arn}/${local.prefix}/*"
  s3_via_service = "s3.${data.aws_region.current.name}.amazonaws.com"
}

# -----------------------------------------------------------------------------
# Encryption key (optional: bring your own with var.kms_key_arn).
# The default key policy delegates to IAM, so the policies below govern usage.
# -----------------------------------------------------------------------------
resource "aws_kms_key" "backups" {
  count = local.create_kms_key ? 1 : 0

  description             = "SSE-KMS key for MySQL backups in ${var.bucket_name}"
  deletion_window_in_days = var.kms_deletion_window_days
  enable_key_rotation     = true
  tags                    = var.tags
}

resource "aws_kms_alias" "backups" {
  count = local.create_kms_key ? 1 : 0

  name          = "alias/${var.bucket_name}"
  target_key_id = aws_kms_key.backups[0].key_id
}

# -----------------------------------------------------------------------------
# Bucket
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "backups" {
  bucket        = var.bucket_name
  force_destroy = var.force_destroy
  tags          = var.tags
}

resource "aws_s3_bucket_ownership_controls" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    object_ownership = "BucketOwnerEnforced" # ACLs disabled
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket = aws_s3_bucket.backups.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = local.kms_key_arn
    }
    bucket_key_enabled = true # fewer KMS calls, lower cost
  }
}

# -----------------------------------------------------------------------------
# Retention lives here, not in a cleanup script: S3 enforces it even when the
# backup job, the host or the CI server is down.
# -----------------------------------------------------------------------------
resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  # Noncurrent-version rules require versioning to be configured first.
  depends_on = [aws_s3_bucket_versioning.backups]

  # Tiering only applies to objects > 128 KiB: smaller objects (the metadata
  # JSON) are billed as 128 KiB in IA/Glacier IR, so they stay in STANDARD.
  rule {
    id     = "tier-backup-artifacts"
    status = "Enabled"

    filter {
      and {
        prefix                   = "${local.prefix}/"
        object_size_greater_than = 131072
      }
    }

    transition {
      days          = var.transition_to_ia_days
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = var.transition_to_archive_days
      storage_class = var.archive_storage_class
    }
  }

  rule {
    id     = "expire-backups"
    status = "Enabled"

    filter {
      prefix = "${local.prefix}/"
    }

    expiration {
      days = var.expiration_days
    }

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = var.abort_incomplete_multipart_days
    }
  }

  rule {
    id     = "remove-expired-delete-markers"
    status = "Enabled"

    filter {
      prefix = "${local.prefix}/"
    }

    expiration {
      expired_object_delete_marker = true
    }
  }

  lifecycle {
    precondition {
      condition     = var.transition_to_archive_days >= var.transition_to_ia_days + 30
      error_message = "transition_to_archive_days must be at least 30 days after transition_to_ia_days (S3 minimum in STANDARD_IA)."
    }

    precondition {
      condition     = var.expiration_days > var.transition_to_archive_days
      error_message = "expiration_days must be greater than transition_to_archive_days."
    }
  }
}

# -----------------------------------------------------------------------------
# Bucket policy: TLS only, and no uploads with a weaker encryption mode or a
# different KMS key than the bucket's own.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.backups.arn, "${aws_s3_bucket.backups.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid       = "DenyNonKmsEncryptionHeader"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.backups.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "StringNotEqualsIfExists"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
  }

  statement {
    sid       = "DenyForeignKmsKey"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.backups.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "StringNotEqualsIfExists"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = [local.kms_key_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "backups" {
  bucket = aws_s3_bucket.backups.id
  policy = data.aws_iam_policy_document.bucket.json

  # Avoid racing the public access block on first apply.
  depends_on = [aws_s3_bucket_public_access_block.backups]
}

# -----------------------------------------------------------------------------
# Least-privilege identity policies. Attach them to the role / instance profile
# used by the backup host and by restore targets respectively. Neither can
# delete objects or versions: expiry is left entirely to the lifecycle rules.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "backup_writer" {
  # amazon.aws.s3_object checks key existence (HeadObject) before uploading;
  # ListBucket turns "not found" into a 404 instead of a 403. Not scoped with
  # s3:prefix because HeadBucket requests carry no prefix; the bucket is
  # dedicated to backups, so this only exposes backup key names.
  statement {
    sid       = "ListBackupBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.backups.arn]
  }

  statement {
    sid = "WriteBackupObjects"
    actions = [
      "s3:PutObject",
      "s3:GetObjectTagging", # s3_object reads tags back after an upload
    ]
    resources = [local.objects_arn]
  }

  statement {
    sid = "UseBackupKeyViaS3"
    actions = [
      "kms:GenerateDataKey",
      "kms:Decrypt", # required to complete multipart uploads of large dumps
    ]
    resources = [local.kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = [local.s3_via_service]
    }
  }
}

data "aws_iam_policy_document" "restore_reader" {
  statement {
    sid       = "ListBackupBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.backups.arn]
  }

  statement {
    sid       = "ReadBackupObjects"
    actions   = ["s3:GetObject"]
    resources = [local.objects_arn]
  }

  statement {
    sid       = "DecryptViaS3"
    actions   = ["kms:Decrypt"]
    resources = [local.kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = [local.s3_via_service]
    }
  }
}

resource "aws_iam_policy" "backup_writer" {
  count = var.create_iam_policies ? 1 : 0

  name        = "${var.iam_policy_name_prefix}-writer"
  description = "Write-only access to MySQL backups in ${var.bucket_name}"
  policy      = data.aws_iam_policy_document.backup_writer.json
  tags        = var.tags
}

resource "aws_iam_policy" "restore_reader" {
  count = var.create_iam_policies ? 1 : 0

  name        = "${var.iam_policy_name_prefix}-restore-reader"
  description = "Read-only access to MySQL backups in ${var.bucket_name}"
  policy      = data.aws_iam_policy_document.restore_reader.json
  tags        = var.tags
}

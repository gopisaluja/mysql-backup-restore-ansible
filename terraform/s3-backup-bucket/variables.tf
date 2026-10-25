variable "bucket_name" {
  description = "Globally unique name of the dedicated backup bucket."
  type        = string
}

variable "backup_prefix" {
  description = "Key prefix the Ansible roles write under (mysql_backup_s3_prefix), without leading or trailing slash."
  type        = string
  default     = "mysql"

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_/-]*[A-Za-z0-9]$", var.backup_prefix))
    error_message = "backup_prefix must not start or end with '/' and may only contain letters, digits, '_', '-' and '/'."
  }
}

variable "kms_key_arn" {
  description = "Existing KMS key ARN for SSE-KMS. Leave null to create a dedicated key with rotation enabled."
  type        = string
  default     = null
}

variable "kms_deletion_window_days" {
  description = "Waiting period before a created KMS key is deleted."
  type        = number
  default     = 30
}

variable "transition_to_ia_days" {
  description = "Days after creation before backup artifacts move to STANDARD_IA (S3 minimum is 30)."
  type        = number
  default     = 30

  validation {
    condition     = var.transition_to_ia_days >= 30
    error_message = "S3 does not allow transitions to STANDARD_IA earlier than 30 days."
  }
}

variable "transition_to_archive_days" {
  description = "Days after creation before backup artifacts move to the archive storage class."
  type        = number
  default     = 90
}

variable "archive_storage_class" {
  description = <<-EOT
    Archive tier. GLACIER_IR keeps millisecond reads, so the restore role works unchanged.
    GLACIER / DEEP_ARCHIVE are cheaper but need a RestoreObject request (hours) before a download.
  EOT
  type        = string
  default     = "GLACIER_IR"

  validation {
    condition     = contains(["GLACIER_IR", "GLACIER", "DEEP_ARCHIVE"], var.archive_storage_class)
    error_message = "archive_storage_class must be GLACIER_IR, GLACIER or DEEP_ARCHIVE."
  }
}

variable "expiration_days" {
  description = "Days after creation before backups expire (become noncurrent versions)."
  type        = number
  default     = 365
}

variable "noncurrent_version_expiration_days" {
  description = "Days a noncurrent (expired or overwritten) version is kept before permanent deletion."
  type        = number
  default     = 30
}

variable "abort_incomplete_multipart_days" {
  description = "Days before incomplete multipart uploads (e.g. an interrupted backup) are cleaned up."
  type        = number
  default     = 7
}

variable "create_iam_policies" {
  description = "Create managed IAM policies from the backup-writer and restore-reader documents."
  type        = bool
  default     = true
}

variable "iam_policy_name_prefix" {
  description = "Name prefix for the managed IAM policies."
  type        = string
  default     = "mysql-backups"
}

variable "force_destroy" {
  description = "Allow terraform destroy to delete a non-empty bucket. Keep false outside of sandboxes."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to every taggable resource."
  type        = map(string)
  default     = {}
}

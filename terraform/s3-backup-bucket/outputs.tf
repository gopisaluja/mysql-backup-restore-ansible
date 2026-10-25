output "bucket_name" {
  description = "Backup bucket name (mysql_backup_s3_bucket / mysql_restore_s3_bucket)."
  value       = aws_s3_bucket.backups.id
}

output "bucket_arn" {
  description = "Backup bucket ARN."
  value       = aws_s3_bucket.backups.arn
}

output "kms_key_arn" {
  description = "KMS key ARN used for SSE-KMS (optionally mysql_backup_s3_kms_key_id)."
  value       = local.kms_key_arn
}

output "backup_writer_policy_json" {
  description = "Least-privilege policy document for the backup host."
  value       = data.aws_iam_policy_document.backup_writer.json
}

output "restore_reader_policy_json" {
  description = "Least-privilege policy document for restore targets."
  value       = data.aws_iam_policy_document.restore_reader.json
}

output "backup_writer_policy_arn" {
  description = "Managed policy ARN for the backup host (null when create_iam_policies = false)."
  value       = try(aws_iam_policy.backup_writer[0].arn, null)
}

output "restore_reader_policy_arn" {
  description = "Managed policy ARN for restore targets (null when create_iam_policies = false)."
  value       = try(aws_iam_policy.restore_reader[0].arn, null)
}

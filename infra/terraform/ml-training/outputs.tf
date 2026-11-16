output "bucket" {
  description = "Training bucket name."
  value       = aws_s3_bucket.ml.bucket
}

output "training_role_arn" {
  description = "Pass as --role-arn to create-training-job."
  value       = aws_iam_role.training.arn
}

output "kms_key_arn" {
  description = "Pass as OutputDataConfig.KmsKeyId and ResourceConfig.VolumeKmsKeyId."
  value       = aws_kms_key.ml.arn
}

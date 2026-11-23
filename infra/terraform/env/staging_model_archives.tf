# Retain the artifacts between windows; only the task-role read follows the arm switch.
variable "staging_qa_model_archives" {
  type = object({
    v9_sha256  = string
    v9b_sha256 = string
    allow_read = optional(bool, false)
  })
  default     = null
  description = "Optional digest-pinned staging checkpoints. Provision storage before the upload, then enable reads for an approved analyzer window."

  validation {
    condition = var.staging_qa_model_archives == null ? true : (
      var.environment == "staging" && var.region == "eu-north-1" && var.assume_role_arn == "" &&
      length(var.allowed_account_ids) == 1 &&
      alltrue([for digest in [var.staging_qa_model_archives.v9_sha256, var.staging_qa_model_archives.v9b_sha256] : can(regex("^[a-f0-9]{64}$", digest))]) &&
      var.staging_qa_model_archives.v9_sha256 != var.staging_qa_model_archives.v9b_sha256
    )
    error_message = "Staging archives require a pinned Stockholm staging account and two distinct lowercase SHA-256 archive digests."
  }
}

locals {
  staging_model_store      = var.staging_qa_model_archives != null
  staging_model_read       = local.staging_qa_armed && try(var.staging_qa_model_archives.allow_read, false)
  staging_model_bucket     = "${local.name_prefix}-qa-model-archives-${local.staging_qa_account}"
  staging_model_bucket_arn = "arn:aws:s3:::${local.staging_model_bucket}"
  staging_model_keys       = { for tag in ["v9", "v9b"] : tag => "own-model/${tag}.tar.gz" }
  staging_model_env = local.staging_model_read ? [
    { name = "OSRA_OWN_MODEL_S3_BUCKET", value = local.staging_model_bucket },
    { name = "OSRA_OWN_MODEL_S3_REGION", value = var.region },
    { name = "OSRA_OWN_MODEL_V9_S3_KEY", value = local.staging_model_keys.v9 },
    { name = "OSRA_OWN_MODEL_V9B_S3_KEY", value = local.staging_model_keys.v9b },
    { name = "OSRA_OWN_MODEL_V9_ARCHIVE_SHA256", value = var.staging_qa_model_archives.v9_sha256 },
    { name = "OSRA_OWN_MODEL_V9B_ARCHIVE_SHA256", value = var.staging_qa_model_archives.v9b_sha256 },
  ] : []
}

resource "aws_s3_bucket" "staging_model_archives" {
  count         = local.staging_model_store ? 1 : 0
  bucket        = local.staging_model_bucket
  force_destroy = false
}

resource "aws_s3_bucket_public_access_block" "staging_model_archives" {
  count                   = local.staging_model_store ? 1 : 0
  bucket                  = aws_s3_bucket.staging_model_archives[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "staging_model_archives" {
  count  = local.staging_model_store ? 1 : 0
  bucket = aws_s3_bucket.staging_model_archives[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "staging_model_archives" {
  count  = local.staging_model_store ? 1 : 0
  bucket = aws_s3_bucket.staging_model_archives[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [local.staging_model_bucket_arn, "${local.staging_model_bucket_arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.staging_model_archives]
}

resource "aws_iam_role_policy" "staging_model_archive_read" {
  count = local.staging_model_read ? 1 : 0
  role  = aws_iam_role.staging_qa_analyzer_task[0].name
  name  = "ReadStagingModelArchives"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = [for key in values(local.staging_model_keys) : "${local.staging_model_bucket_arn}/${key}"]
    }]
  })
  depends_on = [aws_s3_bucket_policy.staging_model_archives, aws_s3_bucket_server_side_encryption_configuration.staging_model_archives]
}

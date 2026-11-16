# One private bucket for training text in and model files out. Nothing here is served to anyone:
# the API never reads it, and the bucket policy denies every principal except the roles named below.

resource "aws_kms_key" "ml" {
  description             = "OSRA ML training bucket"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_kms_alias" "ml" {
  name          = "alias/${local.name}"
  target_key_id = aws_kms_key.ml.key_id
}

resource "aws_s3_bucket" "ml" {
  bucket = local.bucket_name
}

resource "aws_s3_bucket_public_access_block" "ml" {
  bucket                  = aws_s3_bucket.ml.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "ml" {
  bucket = aws_s3_bucket.ml.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "ml" {
  bucket = aws_s3_bucket.ml.id

  rule {
    bucket_key_enabled = true

    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.ml.arn
    }
  }
}

# No versioning: training text must really be gone when it is deleted or expires.
resource "aws_s3_bucket_lifecycle_configuration" "ml" {
  bucket = aws_s3_bucket.ml.id

  rule {
    id     = "expire-everything"
    status = "Enabled"

    filter {}

    expiration {
      days = var.expire_after_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 2
    }
  }
}

data "aws_iam_policy_document" "bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.ml.arn,
      "${aws_s3_bucket.ml.arn}/*",
    ]

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
    sid     = "DenyEveryoneElse"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.ml.arn,
      "${aws_s3_bucket.ml.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = concat([aws_iam_role.training.arn], var.operator_role_arns)
    }
  }
}

resource "aws_s3_bucket_policy" "ml" {
  bucket = aws_s3_bucket.ml.id
  policy = data.aws_iam_policy_document.bucket.json

  depends_on = [aws_s3_bucket_public_access_block.ml]
}

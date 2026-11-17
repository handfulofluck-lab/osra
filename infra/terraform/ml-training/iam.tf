# The role a SageMaker training job runs as. It can read its input, write its output, write its own
# logs and pull the AWS training image. It has no path to RDS, Secrets Manager or the API buckets.

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["sagemaker.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "training" {
  name                 = local.name
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  permissions_boundary = var.permissions_boundary_arn
}

data "aws_iam_policy_document" "training" {
  statement {
    sid       = "ListOwnPrefixes"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.ml.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${local.input_prefix}/*", "${local.output_prefix}/*", "${local.ckpt_prefix}/*"]
    }
  }

  statement {
    sid       = "ReadInput"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.ml.arn}/${local.input_prefix}/*"]
  }

  statement {
    sid     = "WriteOutput"
    actions = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"]
    resources = [
      "${aws_s3_bucket.ml.arn}/${local.output_prefix}/*",
      "${aws_s3_bucket.ml.arn}/${local.ckpt_prefix}/*",
    ]
  }

  statement {
    sid       = "UseBucketKey"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:Encrypt", "kms:DescribeKey"]
    resources = [aws_kms_key.ml.arn]
  }

  # A job that sets ResourceConfig.VolumeKmsKeyId makes SageMaker create a grant on the key for the
  # training volume. Only grants made for an AWS service are allowed.
  statement {
    sid       = "GrantForTrainingVolume"
    actions   = ["kms:CreateGrant"]
    resources = [aws_kms_key.ml.arn]

    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }

  statement {
    sid = "OwnLogs"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = [
      "arn:aws:logs:${var.region}:${local.account_id}:log-group:/aws/sagemaker/TrainingJobs",
      "arn:aws:logs:${var.region}:${local.account_id}:log-group:/aws/sagemaker/TrainingJobs:*",
    ]
  }

  statement {
    sid       = "OwnMetrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["/aws/sagemaker/TrainingJobs"]
    }
  }

  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "PullTrainingImage"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = var.training_image_repository_arns
  }
}

resource "aws_iam_role_policy" "training" {
  name   = "training"
  role   = aws_iam_role.training.id
  policy = data.aws_iam_policy_document.training.json
}

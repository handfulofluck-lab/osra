# The publisher is independent of the API and analyzer task stacks. It can
# write only to this repository and does not receive ECS or Bedrock access.
resource "aws_ecr_repository" "staging_qa_analyzer" {
  count = var.staging_qa_analyzer_publisher_enabled ? 1 : 0

  name                 = "${local.name_prefix}/qa-ai-engine"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_iam_role" "staging_qa_analyzer_publish" {
  count = var.staging_qa_analyzer_publisher_enabled ? 1 : 0

  name               = "${local.name_prefix}-qa-analyzer-publish"
  assume_role_policy = data.aws_iam_policy_document.publish_assume[0].json
}

resource "aws_iam_role_policy" "staging_qa_analyzer_publish" {
  count = var.staging_qa_analyzer_publisher_enabled ? 1 : 0

  role = aws_iam_role.staging_qa_analyzer_publish[0].id
  name = "PublishStagingQaAnalyzer"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrLogin"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = ["*"]
      },
      {
        Sid    = "PublishAndVerifyAnalyzer"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeImages",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
        ]
        Resource = [aws_ecr_repository.staging_qa_analyzer[0].arn]
      },
    ]
  })
}

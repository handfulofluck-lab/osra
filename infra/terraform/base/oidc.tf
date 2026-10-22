# --- GitHub Actions publishing — a role assumed over OIDC, never a long-lived key (ADR-0028 §8) ---
# Everything here is created only when github_repo is set, so a stack that does not publish from
# Actions keeps working with an empty variable and no provider in the account.

locals {
  # `github_repo` is owner/repo; the immutable subject form inserts an ID after each name.
  github_parts = var.github_repo != "" ? split("/", var.github_repo) : []
  github_owner = try(local.github_parts[0], "")
  github_name  = try(local.github_parts[1], "")
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.github_repo != "" ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # AWS validates GitHub against its own trusted root CAs and ignores this, but keeping it is explicit.
  thumbprint_list = ["1c58a3a8518e8759bf075b76b750d4f2df264fcd"]

  tags = {
    Name = "${local.name_prefix}-github-oidc"
  }
}

data "aws_iam_policy_document" "publish_assume" {
  count = var.github_repo != "" ? 1 : 0

  statement {
    sid     = "GitHubActionsWebIdentity"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github[0].arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # `ref:refs/heads/main` is what workflow_dispatch on main presents; `environment:staging-publish`
    # is the tighter form a job pinned to that GitHub environment presents, so both are listed.
    # Repositories created after 2026-07-15 put `@owner-id`/`@repo-id` in the subject, so both forms
    # are listed — the ID wildcards still require the same owner and repository names.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repo}:ref:refs/heads/main",
        "repo:${var.github_repo}:environment:staging-publish",
        "repo:${local.github_owner}@*/${local.github_name}@*:ref:refs/heads/main",
        "repo:${local.github_owner}@*/${local.github_name}@*:environment:staging-publish",
      ]
    }
  }
}

# The only identity that may push images, and the policy below limits it to one repository.
resource "aws_iam_role" "publish" {
  count = var.github_repo != "" ? 1 : 0

  name               = "${local.name_prefix}-publish"
  assume_role_policy = data.aws_iam_policy_document.publish_assume[0].json

  tags = {
    Name = "${local.name_prefix}-publish"
  }
}

data "aws_iam_policy_document" "publish_ecr" {
  count = var.github_repo != "" ? 1 : 0

  # GetAuthorizationToken is account-wide by design and cannot be scoped to a repository.
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # Exactly the calls a layer push makes: no ecr:*, and no other service at all.
  statement {
    sid = "PushApiImage"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
    ]
    resources = [aws_ecr_repository.api.arn]
  }
}

resource "aws_iam_role_policy" "publish_ecr" {
  count = var.github_repo != "" ? 1 : 0

  name   = "${local.name_prefix}-publish-ecr"
  role   = aws_iam_role.publish[0].id
  policy = data.aws_iam_policy_document.publish_ecr[0].json
}

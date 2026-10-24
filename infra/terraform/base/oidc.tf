# --- GitHub Actions publishing — a role assumed over OIDC, never a long-lived key (ADR-0028 §8) ---
# Everything here is created only when github_repo is set, so a stack that does not publish from
# Actions keeps working with an empty variable and no provider in the account.

locals {
  # `github_repo` is owner/repo; the immutable subject form inserts a numeric ID after each name.
  github_parts = var.github_repo != "" ? split("/", var.github_repo) : []
  github_owner = try(local.github_parts[0], "")
  github_name  = try(local.github_parts[1], "")
  # All three are needed: a subject without the IDs would accept a re-registered owner or repository
  # name, which is the whole protection the immutable form buys (review 1 on #295).
  github_oidc_enabled = (
    var.github_repo != "" && var.github_owner_id != "" && var.github_repo_id != ""
  )
}

resource "aws_iam_openid_connect_provider" "github" {
  count = local.github_oidc_enabled ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # AWS validates GitHub against its own trusted root CAs and ignores this, but keeping it is explicit.
  thumbprint_list = ["1c58a3a8518e8759bf075b76b750d4f2df264fcd"]

  tags = {
    Name = "${local.name_prefix}-github-oidc"
  }

  # prevent_destroy: these three exist only when base/terraform.tfvars names the repository, and base
  # state is shared in S3 — so an apply from a clone WITHOUT that gitignored file evaluates the count to
  # zero and DELETES them, which looks identical to a first-time apply (issue #337). To retire these on
  # purpose, remove this lifecycle block in the same change that empties the values.
  lifecycle {
    prevent_destroy = true
  }
}

data "aws_iam_policy_document" "publish_assume" {
  count = local.github_oidc_enabled ? 1 : 0

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

    # Exactly one subject, with the numeric IDs: `repo:OWNER@OWNER-ID/REPO@REPO-ID:ref:refs/heads/main`.
    # The name-only form can never match this repository (GitHub switched the default subject format on
    # 2026-07-15 and this repository was created later), and an `@*` wildcard would let a deleted and
    # re-registered owner mint a matching token.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${local.github_owner}@${var.github_owner_id}/${local.github_name}@${var.github_repo_id}:ref:refs/heads/main",
      ]
    }
  }
}

# The only identity that may push images, and the policy below limits it to one repository.
resource "aws_iam_role" "publish" {
  count = local.github_oidc_enabled ? 1 : 0

  name               = "${local.name_prefix}-publish"
  assume_role_policy = data.aws_iam_policy_document.publish_assume[0].json

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name = "${local.name_prefix}-publish"
  }
}

data "aws_iam_policy_document" "publish_ecr" {
  count = local.github_oidc_enabled ? 1 : 0

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
  count = local.github_oidc_enabled ? 1 : 0

  name   = "${local.name_prefix}-publish-ecr"
  role   = aws_iam_role.publish[0].id
  policy = data.aws_iam_policy_document.publish_ecr[0].json
}

# --- ADR-0033: measuring candidate models on Amazon Bedrock, inside the EU, from GitHub Actions ---
#
# `ai-eval-bedrock.yml` sends the synthetic evaluation set — messages we wrote, about children who do not
# exist — to one candidate model per run. The role trusts the same subject as `publish` (this
# repository's `main`) and may call Bedrock models in EU regions and nothing else: no other service, no
# region outside the EU, and no global or US inference profile, because ADR-0033 decision 1 rules them out.
# It cannot subscribe to a Marketplace model either: accepting a model's terms is Karim's decision 1.

locals {
  # EU member-state regions (London and Zurich are not in the EU). Kept equal to `EU_REGIONS` in
  # services/ai-engine/eval/bedrock_scorer.py, which refuses the same routes before a request is made.
  bedrock_eu_regions = ["eu-central-1", "eu-north-1", "eu-west-1", "eu-west-3", "eu-south-1", "eu-south-2"]
}

data "aws_caller_identity" "current" {}

resource "aws_iam_role" "bedrock_eval" {
  count = local.github_oidc_enabled ? 1 : 0

  name                 = "${local.name_prefix}-bedrock-eval"
  assume_role_policy   = data.aws_iam_policy_document.publish_assume[0].json
  max_session_duration = 3600

  tags = {
    Name = "${local.name_prefix}-bedrock-eval"
  }
}

data "aws_iam_policy_document" "bedrock_eval" {
  count = local.github_oidc_enabled ? 1 : 0

  statement {
    sid = "InvokeEuModelsOnly"
    # Converse is authorised as InvokeModel.
    actions = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    resources = flatten([
      for region in local.bedrock_eu_regions : [
        "arn:aws:bedrock:${region}::foundation-model/*",
        "arn:aws:bedrock:${region}:${data.aws_caller_identity.current.account_id}:inference-profile/eu.*",
      ]
    ])
  }
}

resource "aws_iam_role_policy" "bedrock_eval" {
  count = local.github_oidc_enabled ? 1 : 0

  name   = "${local.name_prefix}-bedrock-eval"
  role   = aws_iam_role.bedrock_eval[0].id
  policy = data.aws_iam_policy_document.bedrock_eval[0].json
}

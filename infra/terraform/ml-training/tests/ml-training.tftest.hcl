# Plan-only checks with a mocked AWS provider: no credentials, nothing is created.
# They pin the three things the README promises: who can reach the bucket, what the training role
# can do, and who can assume it.

mock_provider "aws" {
  override_during = plan

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "000000000000"
    }
  }
  # A mocked policy document has a random string for `json`; resources that take a policy need real JSON.
  # The assertions below read the documents' statements, not this placeholder.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_resource "aws_kms_key" {
    defaults = {
      arn    = "arn:aws:kms:eu-central-1:000000000000:key/test"
      key_id = "test"
    }
  }
  mock_resource "aws_s3_bucket" {
    defaults = {
      arn = "arn:aws:s3:::osra-ml-training-test"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::000000000000:role/osra-ml-training"
    }
  }
}

variables {
  allowed_account_ids = ["000000000000"]
  operator_role_arns = [
    "arn:aws:iam::000000000000:role/deploy",
    "arn:aws:iam::000000000000:role/uploader",
  ]
  budget_alert_emails = ["alarms@example.com"]
}

run "bucket_denies_everyone_but_the_named_roles" {
  command = plan

  assert {
    condition = [
      for s in data.aws_iam_policy_document.bucket.statement : [
        for c in s.condition : "${s.effect}|${c.test}|${c.variable}|${join(",", sort(c.values))}"
      ][0] if s.sid == "DenyEveryoneElse"
      ] == [
      "Deny|ArnNotEquals|aws:PrincipalArn|arn:aws:iam::000000000000:role/deploy,arn:aws:iam::000000000000:role/osra-ml-training,arn:aws:iam::000000000000:role/uploader"
    ]
    error_message = "DenyEveryoneElse must be a Deny with ArnNotEquals on exactly the training role plus operator_role_arns."
  }
}

run "role_policy_has_no_unscoped_statement_beyond_the_two_known" {
  command = plan

  assert {
    condition = join(",", sort([
      for s in data.aws_iam_policy_document.training.statement : s.sid if contains(tolist(s.resources), "*")
    ])) == "EcrLogin,OwnMetrics"
    error_message = "Only EcrLogin and OwnMetrics may use Resource = \"*\" in the training role policy."
  }

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.training.statement : alltrue([for a in s.actions : !endswith(a, "*")])
    ])
    error_message = "No wildcard actions in the training role policy."
  }
}

run "only_sagemaker_in_this_account_can_assume_the_role" {
  command = plan

  assert {
    condition = [
      for s in data.aws_iam_policy_document.assume.statement : join(";", concat(
        [for p in s.principals : "${p.type}=${join(",", sort(p.identifiers))}"],
        [for c in s.condition : "${c.test}|${c.variable}|${join(",", c.values)}"],
      ))
    ] == ["Service=sagemaker.amazonaws.com;StringEquals|aws:SourceAccount|000000000000"]
    error_message = "The trust policy must name only sagemaker.amazonaws.com, with the account condition."
  }
}

run "budget_needs_someone_to_alert" {
  command = plan

  variables {
    budget_alert_emails = []
  }

  expect_failures = [var.budget_alert_emails]
}

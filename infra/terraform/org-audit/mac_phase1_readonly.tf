# Phase1 preparation (#893): explicit infrastructure metadata only. The owner-reviewed alias mapping,
# trust setup and private acceptance evidence are prerequisites; no role is created or re-trusted here.
variable "mac_phase1_regions" {
  description = "Approved metadata regions from the private phase1 scope; no default or guessed region."
  type        = set(string)

  validation {
    condition     = length(var.mac_phase1_regions) > 0 && alltrue([for region in var.mac_phase1_regions : can(regex("^[a-z]{2}-[a-z]+-[0-9]+$", region))])
    error_message = "Supply the explicitly approved metadata regions."
  }
}

variable "mac_phase1_entry_role_names" {
  description = "Production-thread alias to exact reviewed production role path/name. No role or account is inferred."
  type        = map(string)

  validation {
    condition = length(var.mac_phase1_entry_role_names) > 0 && alltrue([
      for alias, name in var.mac_phase1_entry_role_names : can(regex("^[a-z][a-z0-9-]{0,47}$", alias)) &&
      can(regex("^[A-Za-z0-9_+=,.@/-]{1,512}$", name)) && !startswith(name, "/") && !startswith(name, "aws-reserved/")
    ])
    error_message = "Supply the reviewed aliases and role names; reserved owner roles and guessed wildcard targets are refused."
  }
}

locals {
  mac_phase1_accounts  = distinct([local.account_id, var.production_account_id])
  mac_phase1_role_arns = { for alias, name in var.mac_phase1_entry_role_names : alias => "arn:aws:iam::${var.production_account_id}:role/${name}" }

  # Literal actions only. Content/credential-returning reads are not an infrastructure read grant.
  mac_phase1_metadata_specs = {
    AccountMetadata = {
      actions = [
        "ecs:ListClusters", "ecs:ListServices",
        "elasticloadbalancing:DescribeLoadBalancers", "elasticloadbalancing:DescribeTargetGroups", "elasticloadbalancing:DescribeTargetHealth",
        "elasticloadbalancing:DescribeListeners", "elasticloadbalancing:DescribeRules", "elasticloadbalancing:DescribeLoadBalancerAttributes",
        "ec2:DescribeVpcs", "ec2:DescribeSubnets", "ec2:DescribeRouteTables", "ec2:DescribeSecurityGroups", "ec2:DescribeNetworkAcls",
        "ec2:DescribeNatGateways", "ec2:DescribeInternetGateways", "ec2:DescribeVpcEndpoints", "ec2:DescribeNetworkInterfaces",
        "cloudwatch:ListMetrics", "cloudwatch:GetMetricData", "cloudwatch:GetMetricStatistics", "cloudwatch:DescribeAlarmsForMetric",
        "backup:ListBackupJobs", "backup:DescribeBackupJob", "backup:ListRestoreJobs", "backup:DescribeRestoreJob", "backup:ListBackupVaults",
        "config:DescribeConfigRules", "config:DescribeComplianceByConfigRule", "config:DescribeComplianceByResource",
        "config:DescribeConfigurationRecorders", "config:DescribeConfigurationRecorderStatus", "config:DescribeDeliveryChannels",
        "config:DescribeDeliveryChannelStatus", "config:GetComplianceSummaryByConfigRule", "cloudtrail:DescribeTrails",
      ]
      resources = ["*"]
    }
    Clusters = {
      actions   = ["ecs:DescribeClusters"]
      resources = flatten([for account in local.mac_phase1_accounts : [for region in var.mac_phase1_regions : "arn:aws:ecs:${region}:${account}:cluster/*"]])
    }
    Services = {
      actions   = ["ecs:DescribeServices"]
      resources = flatten([for account in local.mac_phase1_accounts : [for region in var.mac_phase1_regions : "arn:aws:ecs:${region}:${account}:service/*"]])
    }
    Images = {
      actions   = ["ecr:DescribeRepositories", "ecr:DescribeImages", "ecr:ListImages"]
      resources = flatten([for account in local.mac_phase1_accounts : [for region in var.mac_phase1_regions : "arn:aws:ecr:${region}:${account}:repository/*"]])
    }
    Databases = {
      actions   = ["rds:DescribeDBInstances"]
      resources = flatten([for account in local.mac_phase1_accounts : [for region in var.mac_phase1_regions : "arn:aws:rds:${region}:${account}:db:*"]])
    }
    Snapshots = {
      actions   = ["rds:DescribeDBSnapshots", "rds:DescribeDBSnapshotAttributes"]
      resources = flatten([for account in local.mac_phase1_accounts : [for region in var.mac_phase1_regions : "arn:aws:rds:${region}:${account}:snapshot:*"]])
    }
    Alarms = {
      actions   = ["cloudwatch:DescribeAlarms", "cloudwatch:DescribeAlarmHistory"]
      resources = flatten([for account in local.mac_phase1_accounts : [for region in var.mac_phase1_regions : "arn:aws:cloudwatch:${region}:${account}:alarm:*"]])
    }
    Vaults = {
      actions   = ["backup:DescribeBackupVault", "backup:ListRecoveryPointsByBackupVault"]
      resources = flatten([for account in local.mac_phase1_accounts : [for region in var.mac_phase1_regions : "arn:aws:backup:${region}:${account}:backup-vault:*"]])
    }
    RecoveryPoints = {
      actions = ["backup:DescribeRecoveryPoint"]
      resources = flatten([for account in local.mac_phase1_accounts : [for region in var.mac_phase1_regions : [
      "arn:aws:backup:${region}:${account}:recovery-point:*", "arn:aws:rds:${region}:${account}:snapshot:*"]]])
    }
    Trails = {
      actions   = ["cloudtrail:GetTrailStatus"]
      resources = flatten([for account in local.mac_phase1_accounts : [for region in var.mac_phase1_regions : "arn:aws:cloudtrail:${region}:${account}:trail/*"]])
    }
  }
  mac_phase1_metadata_actions = sort(distinct(flatten([for spec in local.mac_phase1_metadata_specs : spec.actions])))
  mac_phase1_role_actions     = ["sts:AssumeRole", "sts:SetSourceIdentity"]
  mac_phase1_data_denies = [
    "iam:*", "organizations:*", "secretsmanager:GetSecretValue", "secretsmanager:BatchGetSecretValue", "ssm:*", "kms:Decrypt",
    "rds-data:*", "rds-db:connect", "s3:GetObject*", "s3:SelectObjectContent", "s3-object-lambda:GetObject",
    "logs:GetLogEvents", "logs:FilterLogEvents", "logs:StartQuery", "logs:GetQueryResults", "logs:Unmask", "logs:CreateExportTask",
    "dynamodb:GetItem", "dynamodb:BatchGetItem", "dynamodb:Query", "dynamodb:Scan", "dynamodb:PartiQLSelect", "dynamodb:ExecuteStatement",
    "dynamodb:BatchExecuteStatement", "dynamodb:ExecuteTransaction", "dynamodb:GetRecords", "dynamodb:GetShardIterator",
    "ecs:ExecuteCommand", "ecs:DescribeTasks", "ecs:DescribeTaskDefinition", "ecr:GetAuthorizationToken", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer",
    "config:GetResourceConfigHistory", "config:BatchGetResourceConfig", "config:SelectResourceConfig", "config:SelectAggregateResourceConfig", "config:DeliverConfigSnapshot",
    "cloudtrail:LookupEvents",
  ]
  mac_phase1_user_denies = [
    { Sid = "OnlyPhase1Actions", Effect = "Deny", NotAction = concat(local.mac_phase1_metadata_actions, local.mac_phase1_role_actions), Resource = "*" },
    { Sid = "NoContentOrIdentityChanges", Effect = "Deny", Action = local.mac_phase1_data_denies, Resource = "*" },
    { Sid = "OnlyReviewedRegions", Effect = "Deny", NotAction = local.mac_phase1_role_actions, Resource = "*", Condition = { StringNotEquals = { "aws:RequestedRegion" = sort(tolist(var.mac_phase1_regions)) } } },
    { Sid = "OnlyMappedRoleTargets", Effect = "Deny", Action = local.mac_phase1_role_actions, NotResource = values(local.mac_phase1_role_arns) },
    { Sid = "RequireMacSourceIdentity", Effect = "Deny", Action = local.mac_phase1_role_actions, Resource = "*", Condition = { StringNotEquals = { "sts:SourceIdentity" = "osra-codex-mac" } } },
  ]
  mac_phase1_allow_document = jsonencode({
    Version = "2012-10-17"
    Statement = concat([for name, spec in local.mac_phase1_metadata_specs : {
      Sid       = name, Effect = "Allow", Action = spec.actions, Resource = spec.resources
      Condition = { StringEquals = { "aws:RequestedRegion" = sort(tolist(var.mac_phase1_regions)) } }
      }], [{
      Sid       = "ReviewedEntryOnly", Effect = "Allow", Action = local.mac_phase1_role_actions, Resource = values(local.mac_phase1_role_arns)
      Condition = { StringEquals = { "sts:SourceIdentity" = "osra-codex-mac" } }
    }])
  })
  mac_phase1_ceiling_document = jsonencode({ Version = "2012-10-17", Statement = local.mac_phase1_user_denies })
  mac_phase1_role_ceiling_document = jsonencode({
    Version = "2012-10-17"
    Statement = [for statement in local.mac_phase1_user_denies : merge(statement, {
      Condition = merge(try(statement.Condition, {}), { StringEquals = { "aws:SourceIdentity" = "osra-codex-mac" } })
    })]
  })
}

resource "aws_iam_policy" "mac_phase1_readonly" {
  name        = "osra-mac-phase1-metadata"
  description = "Explicit approved infrastructure metadata; no data reads, rotation or write grant."
  policy      = local.mac_phase1_allow_document
  lifecycle {
    precondition {
      condition     = length(local.mac_phase1_allow_document) < 4500
      error_message = "Keep the metadata allow document within the existing policy budget."
    }
  }
}

resource "aws_iam_policy" "mac_phase1_ceiling" {
  name        = "osra-mac-phase1-ceiling"
  description = "Explicit phase1 action, content, region and role-entry deny ceiling."
  policy      = local.mac_phase1_ceiling_document
  lifecycle {
    precondition {
      condition     = length(local.mac_phase1_ceiling_document) < 4500
      error_message = "Keep the phase1 deny ceiling within the existing policy budget."
    }
  }
}

resource "aws_organizations_policy" "mac_phase1_ceiling" {
  name        = "osra-mac-phase1-ceiling"
  description = "Phase1 ceiling for SourceIdentity-attributed Mac sessions in the existing production scope."
  type        = "SERVICE_CONTROL_POLICY"
  content     = local.mac_phase1_role_ceiling_document
  lifecycle {
    precondition {
      condition     = length(local.mac_phase1_role_ceiling_document) < 5120
      error_message = "Keep the phase1 SCP within its unchanged service limit."
    }
  }
}

resource "aws_organizations_policy_attachment" "mac_phase1_ceiling_production" {
  policy_id = aws_organizations_policy.mac_phase1_ceiling.id
  target_id = var.production_account_id
}

resource "aws_iam_user_policy_attachment" "mac_phase1_ceiling" {
  user       = aws_iam_user.codex_mac.name
  policy_arn = aws_iam_policy.mac_phase1_ceiling.arn
}

resource "aws_iam_user_policy_attachment" "mac_phase1_readonly" {
  user       = aws_iam_user.codex_mac.name
  policy_arn = aws_iam_policy.mac_phase1_readonly.arn
  depends_on = [aws_iam_user_policy_attachment.agent_keep_watchers, aws_iam_user_policy_attachment.agent_keep_backups,
    aws_iam_user_policy_attachment.agent_no_escalation, aws_iam_user_policy_attachment.mac_phase1_ceiling,
    aws_iam_user_policy.mac_authorization_deadline, aws_organizations_policy_attachment.agent_cannot_erase_evidence_production,
  aws_organizations_policy_attachment.mac_phase1_ceiling_production]
}

output "mac_phase1_entry_roles" {
  description = "Review-only alias mapping; current role trust and every applicable control require private proof before use."
  value       = local.mac_phase1_role_arns
  sensitive   = true
}

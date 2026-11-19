# Partial expiry enforcement (#893). Terraform renders the approved deadline as a literal date;
# the IAM policy does not substitute a tag into a Date operator. Renewal is a reviewed owner-MFA
# change to BOTH policies and the protected user tag, not a tag-only extension.
locals {
  mac_authorization_deadline_statement = {
    Sid       = "MacAuthorizationExpired"
    Effect    = "Deny"
    Action    = "*"
    Resource  = "*"
    Condition = { DateGreaterThanEquals = { "aws:CurrentTime" = var.mac_access_expires_at } }
  }

  # Apply through the existing production SCP/attachment only after reviewed attribution setup.
  mac_member_deadline_statement = merge(local.mac_authorization_deadline_statement, {
    Condition = merge(local.mac_authorization_deadline_statement.Condition, {
      StringEquals = { "aws:SourceIdentity" = "osra-codex-mac" }
    })
  })
}

resource "aws_iam_user_policy" "mac_authorization_deadline" {
  name = "fixed-authorization-deadline"
  user = aws_iam_user.codex_mac.name
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [local.mac_authorization_deadline_statement]
  })
}

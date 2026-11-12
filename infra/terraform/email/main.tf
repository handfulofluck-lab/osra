# Outbound email for the API (Play decision 11 A: AWS SES replaces Resend; sender code in #573).
#
# - The domain identity, signed with Easy DKIM (2048-bit), its three DKIM CNAMEs in the Route 53 zone.
# - A custom MAIL FROM subdomain (bounce.<domain>) so SPF aligns with the From domain, plus its MX and SPF.
# - A DMARC record in monitor mode (p=none): it reports nothing anywhere, it only tells receivers the
#   domain has a policy. Tightening it is a later step once mail has flowed for a while.
# - The API task role, allowed to send only as this identity. env/ attaches it when email_enabled = true.
#
# A new SES account starts in the sandbox (only verified recipients, 200 a day). Leaving it is an AWS
# request, not Terraform; see README.md.

locals {
  mail_from = "bounce.${var.domain}"

  tags = {
    Project   = "osra"
    Component = "email"
    ManagedBy = "terraform"
  }
}

data "aws_route53_zone" "main" {
  name         = var.domain
  private_zone = false
}

data "aws_caller_identity" "current" {}

# --- Identity + DKIM --------------------------------------------------------------------------

resource "aws_sesv2_email_identity" "domain" {
  email_identity = var.domain

  dkim_signing_attributes {
    next_signing_key_length = "RSA_2048_BIT"
  }
}

resource "aws_route53_record" "dkim" {
  count = 3 # SES always returns three tokens for Easy DKIM

  zone_id = data.aws_route53_zone.main.zone_id
  name    = "${aws_sesv2_email_identity.domain.dkim_signing_attributes[0].tokens[count.index]}._domainkey.${var.domain}"
  type    = "CNAME"
  ttl     = 1800
  records = ["${aws_sesv2_email_identity.domain.dkim_signing_attributes[0].tokens[count.index]}.dkim.amazonses.com"]
}

# --- Custom MAIL FROM (SPF alignment) -----------------------------------------------------------

resource "aws_sesv2_email_identity_mail_from_attributes" "domain" {
  email_identity         = aws_sesv2_email_identity.domain.email_identity
  mail_from_domain       = local.mail_from
  behavior_on_mx_failure = "USE_DEFAULT_VALUE" # fall back to amazonses.com rather than refuse to send
}

resource "aws_route53_record" "mail_from_mx" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = local.mail_from
  type    = "MX"
  ttl     = 1800
  records = ["10 feedback-smtp.${var.region}.amazonses.com"]
}

resource "aws_route53_record" "mail_from_spf" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = local.mail_from
  type    = "TXT"
  ttl     = 1800
  records = ["v=spf1 include:amazonses.com ~all"]
}

# --- DMARC (monitor only) -----------------------------------------------------------------------

resource "aws_route53_record" "dmarc" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "_dmarc.${var.domain}"
  type    = "TXT"
  ttl     = 1800
  records = ["v=DMARC1; p=none"]
}

# --- The API task role: send as this identity, nothing else -------------------------------------

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    # Only tasks in this account can assume it (confused-deputy guard).
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "api_task" {
  name               = "osra-${var.environment}-api-task"
  description        = "Runtime role of the OSRA API task: send email as ${var.domain} through SES."
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "send" {
  statement {
    actions   = ["ses:SendEmail", "ses:SendRawEmail"]
    resources = [aws_sesv2_email_identity.domain.arn]
    # The From address must be on this domain, so a bug cannot send as someone else's address.
    condition {
      test     = "StringLike"
      variable = "ses:FromAddress"
      values   = ["*@${var.domain}"]
    }
  }
}

resource "aws_iam_role_policy" "send" {
  name   = "ses-send-as-${replace(var.domain, ".", "-")}"
  role   = aws_iam_role.api_task.id
  policy = data.aws_iam_policy_document.send.json
}

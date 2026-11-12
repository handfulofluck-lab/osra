# The public website at osratech.com: the privacy policy and the account-deletion page that Google
# Play links to (decision 5). Static files from site/ in a private S3 bucket, served by CloudFront
# with HTTPS. About $1/month at this traffic. The API is a separate stack (base/ + env/).

locals {
  domain    = "osratech.com"
  www       = "www.osratech.com"
  site_root = "${path.module}/../../../site"

  tags = {
    Project   = "osra"
    Component = "website"
    ManagedBy = "terraform"
  }

  content_types = {
    html = "text/html; charset=utf-8"
    css  = "text/css; charset=utf-8"
    txt  = "text/plain; charset=utf-8"
    svg  = "image/svg+xml"
    png  = "image/png"
    ico  = "image/x-icon"
    js   = "text/javascript; charset=utf-8"
  }
}

data "aws_route53_zone" "main" {
  name         = local.domain
  private_zone = false
}

# --- Bucket (private; only this distribution can read it) -----------------------------------

resource "aws_s3_bucket" "site" {
  bucket_prefix = "osra-website-"
  force_destroy = true # the files are all in git; nothing in the bucket is the only copy
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "site" {
  bucket = aws_s3_bucket.site.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "site" {
  bucket = aws_s3_bucket.site.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_object" "file" {
  for_each = fileset(local.site_root, "**")

  bucket       = aws_s3_bucket.site.id
  key          = each.value
  source       = "${local.site_root}/${each.value}"
  etag         = filemd5("${local.site_root}/${each.value}")
  content_type = lookup(local.content_types, reverse(split(".", each.value))[0], "application/octet-stream")
}

data "aws_iam_policy_document" "site" {
  statement {
    sid       = "CloudFrontReadOnly"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.site.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "site" {
  bucket     = aws_s3_bucket.site.id
  policy     = data.aws_iam_policy_document.site.json
  depends_on = [aws_s3_bucket_public_access_block.site]
}

# --- Certificate (us-east-1, DNS-validated in the existing zone) ------------------------------

resource "aws_acm_certificate" "site" {
  provider                  = aws.us_east_1
  domain_name               = local.domain
  subject_alternative_names = [local.www]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "validation" {
  for_each = {
    for dvo in aws_acm_certificate.site.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = data.aws_route53_zone.main.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 300
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "site" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.site.arn
  validation_record_fqdns = [for r in aws_route53_record.validation : r.fqdn]
}

# --- CloudFront ------------------------------------------------------------------------------

# Clean URLs (/privacy -> /privacy/index.html) and one canonical host (www -> apex). S3 behind
# origin access control has no index documents of its own, so this does it at the edge.
resource "aws_cloudfront_function" "rewrite" {
  name    = "osra-website-rewrite"
  runtime = "cloudfront-js-2.0"
  publish = true
  code    = file("${path.module}/rewrite.js")
}

resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "osra-website"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# AWS-managed policies: CachingOptimized and SecurityHeadersPolicy.
data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_response_headers_policy" "security" {
  name = "Managed-SecurityHeadersPolicy"
}

resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "osratech.com website"
  aliases             = [local.domain, local.www]
  default_root_object = "index.html"
  price_class         = "PriceClass_100"
  http_version        = "http2and3"

  origin {
    origin_id                = "site"
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  default_cache_behavior {
    target_origin_id           = "site"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.optimized.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.rewrite.arn
    }
  }

  # A missing page: S3 answers 403 to an unknown key under OAC. Show the home page as a 404.
  custom_error_response {
    error_code            = 403
    response_code         = 404
    response_page_path    = "/index.html"
    error_caching_min_ttl = 60
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.site.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

# --- DNS -------------------------------------------------------------------------------------

resource "aws_route53_record" "alias" {
  for_each = toset(flatten([for name in [local.domain, local.www] : [for t in ["A", "AAAA"] : "${name}|${t}"]]))

  zone_id = data.aws_route53_zone.main.zone_id
  name    = split("|", each.value)[0]
  type    = split("|", each.value)[1]

  alias {
    name                   = aws_cloudfront_distribution.site.domain_name
    zone_id                = aws_cloudfront_distribution.site.hosted_zone_id
    evaluate_target_health = false
  }
}

output "url" {
  value = "https://${local.domain}"
}

output "distribution_id" {
  value = aws_cloudfront_distribution.site.id
}

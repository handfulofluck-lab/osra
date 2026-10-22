# --- Image repository -------------------------------------------------------------------------

# Lives in base, not env: the image must survive `down`, or every session would need a re-push
# and the API could not start until a human rebuilt it.
resource "aws_ecr_repository" "api" {
  name = "${local.name_prefix}/api"

  # Staging reuses a moving tag (for example :staging); production should switch to IMMUTABLE.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  # A forced delete keeps a deliberate base rebuild from failing on leftover test images.
  force_delete = true

  tags = {
    Name = "${local.name_prefix}/api"
  }
}

resource "aws_ecr_lifecycle_policy" "api" {
  repository = aws_ecr_repository.api.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after 14 days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 14
      }
      action = { type = "expire" }
    }]
  })
}

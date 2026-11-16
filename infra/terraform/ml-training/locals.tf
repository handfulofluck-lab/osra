data "aws_caller_identity" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  name        = "osra-ml-training"
  bucket_name = "${local.name}-${local.account_id}-${var.region}"

  tags = {
    Project     = "osra"
    Environment = "production"
    ManagedBy   = "terraform"
    Purpose     = "ml-training"
  }

  # Prefixes the job uses. The role reads input/, writes output/ and checkpoints/, nothing else.
  input_prefix  = "input"
  output_prefix = "output"
  ckpt_prefix   = "checkpoints"
}

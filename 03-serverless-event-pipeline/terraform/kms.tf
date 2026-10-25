# Customer-managed key for the SNS topics. Required, not just nice-to-have: CloudWatch Alarms and
# EventBridge cannot publish to topics encrypted with the AWS-managed `alias/aws/sns` key.
data "aws_iam_policy_document" "sns_key" {
  statement {
    sid       = "AccountAdmin"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid       = "AllowPublishingServices"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com", "events.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "sns" {
  description             = "${var.name} SNS topics"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.sns_key.json
}

resource "aws_kms_alias" "sns" {
  name          = "alias/${var.name}-sns"
  target_key_id = aws_kms_key.sns.key_id
}

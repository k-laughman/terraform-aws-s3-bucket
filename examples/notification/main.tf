locals {
  bucket_name = "s3-bucket-${random_pet.this.id}"
}

resource "random_pet" "this" {
  length = 2
}

module "s3_bucket" {
  source = "../../"

  bucket        = local.bucket_name
  force_destroy = true
}

#############################################
# Using packaged function from Lambda module
#############################################

locals {
  package_url = "https://raw.githubusercontent.com/terraform-aws-modules/terraform-aws-lambda/master/examples/fixtures/python3.8-zip/existing_package.zip"
  downloaded  = "downloaded_package_${md5(local.package_url)}.zip"
}

resource "null_resource" "download_package" {
  triggers = {
    downloaded = local.downloaded
  }

  provisioner "local-exec" {
    command = "curl -L -o ${local.downloaded} ${local.package_url}"
  }
}

data "null_data_source" "downloaded_package" {
  inputs = {
    id       = null_resource.download_package.id
    filename = local.downloaded
  }
}

module "lambda_function1" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 1.0"

  function_name = "${random_pet.this.id}-lambda1"
  handler       = "index.lambda_handler"
  runtime       = "python3.8"

  create_package         = false
  local_existing_package = data.null_data_source.downloaded_package.outputs["filename"]
  tags = {
    yor_name  = "lambda_function1"
    yor_trace = "060c6b2a-193e-47e7-b21b-04acf6f44df2"
  }
}

module "lambda_function2" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 1.0"

  function_name = "${random_pet.this.id}-lambda2"
  handler       = "index.lambda_handler"
  runtime       = "python3.8"

  create_package         = false
  local_existing_package = data.null_data_source.downloaded_package.outputs["filename"]
  tags = {
    yor_name  = "lambda_function2"
    yor_trace = "28fba687-5d5e-4abe-ad6f-26f5439d19cc"
  }
}

module "sns_topic1" {
  source = "terraform-aws-modules/cloudwatch/aws//examples/fixtures/aws_sns_topic"
}

module "sns_topic2" {
  source = "terraform-aws-modules/cloudwatch/aws//examples/fixtures/aws_sns_topic"
}

resource "aws_sqs_queue" "this" {
  count = 2
  name  = "${random_pet.this.id}-${count.index}"
  tags = {
    yor_name  = "this"
    yor_trace = "9b0fbd3a-1e29-472e-bde5-237a4185e614"
  }
}

# SQS policy created outside of the module
data "aws_iam_policy_document" "sqs_external" {
  statement {
    effect  = "Allow"
    actions = ["sqs:SendMessage"]

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }

    resources = [aws_sqs_queue.this[0].arn]
  }
}

resource "aws_sqs_queue_policy" "allow_external" {
  queue_url = aws_sqs_queue.this[0].id
  policy    = data.aws_iam_policy_document.sqs_external.json
}

module "all_notifications" {
  source = "../../modules/notification"

  bucket = module.s3_bucket.this_s3_bucket_id

  # Common error - Error putting S3 notification configuration: InvalidArgument: Configuration is ambiguously defined. Cannot have overlapping suffixes in two rules if the prefixes are overlapping for the same event type.

  lambda_notifications = {
    lambda1 = {
      function_arn  = module.lambda_function1.this_lambda_function_arn
      function_name = module.lambda_function1.this_lambda_function_name
      events        = ["s3:ObjectCreated:Put"]
      filter_prefix = "prefix/"
      filter_suffix = ".json"
    }

    lambda2 = {
      function_arn  = module.lambda_function2.this_lambda_function_arn
      function_name = module.lambda_function2.this_lambda_function_name
      events        = ["s3:ObjectCreated:Post"]
    }
  }

  sqs_notifications = {
    sqs1 = {
      queue_arn     = aws_sqs_queue.this[0].arn
      events        = ["s3:ObjectCreated:Put"]
      filter_prefix = "prefix2/"
      filter_suffix = ".txt"

      #      queue_id =  aws_sqs_queue.this[0].id // optional
    }

    sqs2 = {
      queue_arn = aws_sqs_queue.this[1].arn
      events    = ["s3:ObjectCreated:Copy"]
    }
  }

  sns_notifications = {
    sns1 = {
      topic_arn     = module.sns_topic1.this_sns_topic_arn
      events        = ["s3:ObjectRemoved:Delete"]
      filter_prefix = "prefix3/"
      filter_suffix = ".csv"
    }

    sns2 = {
      topic_arn = module.sns_topic2.this_sns_topic_arn
      events    = ["s3:ObjectRemoved:DeleteMarkerCreated"]
    }
  }

  # Creation of policy is handled outside of the module
  create_sqs_policy = false
}

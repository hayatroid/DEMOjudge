terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "ap-northeast-1"
}

variable "box_minutes" {
  type    = number
  default = 4320
}

# Two is the least that shows a killed host's work being taken up by another.
variable "worker_count" {
  type    = number
  default = 2
}

# Cases measured 0.30-0.39 s on a host, and at 1000 ms a submission that only
# added two numbers failed while the judge took the CPU beside it.
variable "tl_ms" {
  type    = number
  default = 3000
}

# A phase passes too quickly to be watched, so each one is held open this long.
variable "delay_ms" {
  type    = number
  default = 2000
}

# The value must be at least the OTP the shipped BEAM was compiled with, and one
# that builds.hex.pm has built for this distro.
variable "otp_version" {
  type    = string
  default = "29.0.4"
}

variable "nsjail_version" {
  type    = string
  default = "3.4"
}

data "aws_caller_identity" "current" {}

data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_dynamodb_table" "log" {
  # A DynamoDB table name is at least three characters.
  name         = "oj-log"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  stream_enabled   = true
  stream_view_type = "KEYS_ONLY"

  # Only the lease items carry this attribute, so the log never expires.
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }
}

resource "random_password" "token" {
  length  = 24
  special = false
}

locals {
  root = "${path.module}/.."

  # The digest must be taken exactly as bin/ship takes it, since the
  # precondition below compares the two.
  ship_files = sort(concat(
    tolist(fileset(local.root, "src/**")),
    tolist(fileset(local.root, "problems/**")),
    tolist(fileset(local.root, "web/*")),
    ["gleam.toml", "manifest.toml"],
  ))

  ship_hash = sha256(join("", [
    for f in local.ship_files : filesha256("${local.root}/${f}")
  ]))
}

data "archive_file" "ship" {
  type        = "zip"
  source_dir  = "${local.root}/build/ship"
  output_path = "${path.module}/.terraform/oj-ship.zip"

  lifecycle {
    precondition {
      condition     = try(trimspace(file("${local.root}/build/ship/STAMP")), "") == local.ship_hash && fileexists("${local.root}/build/ship/web/index.html")
      error_message = "build/ship was not built from this tree; run bin/ship before apply"
    }
  }
}

resource "aws_s3_bucket" "ship" {
  bucket_prefix = "oj-ship-"
  force_destroy = true
}

resource "aws_s3_object" "ship" {
  bucket = aws_s3_bucket.ship.id
  key    = "oj-ship.zip"
  source = data.archive_file.ship.output_path
  etag   = data.archive_file.ship.output_md5
}

data "aws_vpc" "default" {
  default = true
}

data "aws_availability_zones" "available" {
  state = "available"
}

# An existing default subnet is adopted rather than created, and destroy leaves
# it standing so the next apply starts from a whole VPC.
resource "aws_default_subnet" "worker" {
  availability_zone = data.aws_availability_zones.available.names[0]
}

resource "aws_security_group" "worker" {
  name   = "oj-worker"
  vpc_id = data.aws_vpc.default.id

  # The empty list has to be written out: dropping the block leaves the rules
  # already on the group unmanaged rather than closed.
  ingress = []

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "control" {
  name   = "oj-control"
  vpc_id = data.aws_vpc.default.id

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "node" {
  # No statement grants an update or a delete on a log line, so append-only is a
  # property of the boundary rather than a discipline in the code.
  statement {
    sid       = "AppendOnly"
    actions   = ["dynamodb:PutItem", "dynamodb:Query", "dynamodb:TransactWriteItems"]
    resources = [aws_dynamodb_table.log.arn]

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "dynamodb:LeadingKeys"
      values   = ["LOG"]
    }
  }

  # The node that takes a submission is not the one that judges it, so the body
  # is stored where both reach it.
  statement {
    sid       = "Source"
    actions   = ["dynamodb:PutItem", "dynamodb:GetItem"]
    resources = [aws_dynamodb_table.log.arn]

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "dynamodb:LeadingKeys"
      values   = ["SOURCE"]
    }
  }

  # A stream ARN changes whenever the stream is disabled and enabled again, so
  # the resource is the wildcard under the table.
  statement {
    sid = "ReadStream"
    actions = [
      "dynamodb:ListStreams",
      "dynamodb:DescribeStream",
      "dynamodb:GetShardIterator",
      "dynamodb:GetRecords",
    ]
    resources = ["${aws_dynamodb_table.log.arn}/stream/*"]
  }

  statement {
    sid       = "SourceBundle"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.ship.arn}/${aws_s3_object.ship.key}"]
  }

  statement {
    sid       = "Fleet"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "worker" {
  source_policy_documents = [data.aws_iam_policy_document.node.json]

  # A fenced append condition-checks the lease inside the same transaction, so
  # the lease keys need ConditionCheckItem as well.
  statement {
    sid = "Lease"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:Query",
      "dynamodb:UpdateItem",
      "dynamodb:ConditionCheckItem",
      "dynamodb:TransactWriteItems",
    ]
    resources = [aws_dynamodb_table.log.arn]

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "dynamodb:LeadingKeys"
      values   = ["LEASE"]
    }
  }
}

# Only this document carries SSM and FIS, so no host carrying a runner can stop
# another one.
data "aws_iam_policy_document" "control" {
  source_policy_documents = [data.aws_iam_policy_document.node.json]

  statement {
    sid       = "LeaseRead"
    actions   = ["dynamodb:Query"]
    resources = [aws_dynamodb_table.log.arn]

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "dynamodb:LeadingKeys"
      values   = ["LEASE"]
    }
  }

  statement {
    sid     = "KillInside"
    actions = ["ssm:SendCommand"]
    resources = [
      "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/*",
      "arn:aws:ssm:${var.region}::document/AWS-RunShellScript",
    ]
  }

  statement {
    sid       = "KillInsideResult"
    actions   = ["ssm:GetCommandInvocation"]
    resources = ["*"]
  }

  statement {
    sid     = "StartInjection"
    actions = ["fis:StartExperiment"]
    resources = [
      "arn:aws:fis:${var.region}:${data.aws_caller_identity.current.account_id}:experiment-template/*",
      "arn:aws:fis:${var.region}:${data.aws_caller_identity.current.account_id}:experiment/*",
    ]
  }

  statement {
    sid       = "ReadInjection"
    actions   = ["fis:GetExperiment", "fis:ListExperiments"]
    resources = ["*"]
  }

  statement {
    sid       = "PassFisRole"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.fis.arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["fis.amazonaws.com"]
    }
  }
}

locals {
  node_policies = {
    worker  = data.aws_iam_policy_document.worker.json
    control = data.aws_iam_policy_document.control.json
  }
}

resource "aws_iam_role" "node" {
  for_each           = local.node_policies
  name               = "oj-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
}

resource "aws_iam_role_policy" "node" {
  for_each = local.node_policies
  role     = aws_iam_role.node[each.key].name
  policy   = each.value
}

resource "aws_iam_role_policy_attachment" "ssm" {
  for_each   = local.node_policies
  role       = aws_iam_role.node[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "node" {
  for_each = local.node_policies
  name     = "oj-${each.key}"
  role     = aws_iam_role.node[each.key].name
}

# An experiment needs the account's service-linked role, and without it the
# caller must hold iam:CreateServiceLinkedRole, which no box is given.
resource "aws_iam_service_linked_role" "fis" {
  aws_service_name = "fis.amazonaws.com"
}

data "aws_iam_policy_document" "assume_fis" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["fis.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "fis" {
  statement {
    actions   = ["ec2:DescribeInstances", "ec2:StopInstances", "ec2:StartInstances"]
    resources = ["*"]
  }
}

resource "aws_iam_role" "fis" {
  name               = "oj-fis"
  assume_role_policy = data.aws_iam_policy_document.assume_fis.json
}

resource "aws_iam_role_policy" "fis" {
  role   = aws_iam_role.fis.name
  policy = data.aws_iam_policy_document.fis.json
}

resource "aws_fis_experiment_template" "kill" {
  count = var.worker_count

  description = "stop judge-${count.index} and start it again 2 minutes later"
  role_arn    = aws_iam_role.fis.arn
  depends_on  = [aws_iam_service_linked_role.fis]

  stop_condition {
    source = "none"
  }

  action {
    name      = "stop"
    action_id = "aws:ec2:stop-instances"

    parameter {
      key   = "startInstancesAfterDuration"
      value = "PT2M"
    }

    target {
      key   = "Instances"
      value = "worker"
    }
  }

  target {
    name           = "worker"
    resource_type  = "aws:ec2:instance"
    selection_mode = "ALL"

    resource_tag {
      key   = "OJKill"
      value = "judge-${count.index}"
    }
  }
}

resource "aws_fis_experiment_template" "stop_worker" {
  description = "stop every host carrying a runner and start them again"
  role_arn    = aws_iam_role.fis.arn
  depends_on  = [aws_iam_service_linked_role.fis]

  stop_condition {
    source = "none"
  }

  action {
    name      = "stop"
    action_id = "aws:ec2:stop-instances"

    parameter {
      key   = "startInstancesAfterDuration"
      value = "PT1M"
    }

    target {
      key   = "Instances"
      value = "worker"
    }
  }

  target {
    name           = "worker"
    resource_type  = "aws:ec2:instance"
    selection_mode = "ALL"

    resource_tag {
      key   = "Name"
      value = "oj-worker"
    }
  }
}

locals {
  # An experiment picks its targets by tag: naming the instances from a template
  # would close a loop through the ids their user_data carries.
  fis_templates = join(",", [
    for i, t in aws_fis_experiment_template.kill : "judge-${i}=${t.id}"
  ])

  node_vars = {
    minutes        = var.box_minutes
    region         = var.region
    table          = aws_dynamodb_table.log.name
    token          = random_password.token.result
    bucket         = aws_s3_bucket.ship.id
    object_key     = aws_s3_object.ship.key
    bundle_hash    = data.archive_file.ship.output_base64sha256
    otp_version    = var.otp_version
    nsjail_version = var.nsjail_version
    tl_ms          = var.tl_ms
    delay_ms       = var.delay_ms
    fis_templates  = local.fis_templates
  }
}

# EC2 rather than a managed runtime, because the sandbox wants namespaces and
# cgroups of its own.
resource "aws_instance" "worker" {
  count = var.worker_count

  ami                         = data.aws_ssm_parameter.ubuntu.value
  instance_type               = "t3.micro"
  subnet_id                   = aws_default_subnet.worker.id
  vpc_security_group_ids      = [aws_security_group.worker.id]
  iam_instance_profile        = aws_iam_instance_profile.node["worker"].name
  associate_public_ip_address = true

  root_block_device {
    volume_size           = 8
    volume_type           = "gp3"
    delete_on_termination = true
  }

  user_data                            = templatefile("${path.module}/node.sh.tftpl", merge(local.node_vars, { runners = "1" }))
  user_data_replace_on_change          = true
  instance_initiated_shutdown_behavior = "terminate"

  tags = {
    Name   = "oj-worker"
    OJKill = "judge-${count.index}"
  }
}

# This host carries neither the fleet's Name nor a kill tag, and both the fleet
# listing and an experiment's targets are matched by tag value alone.
resource "aws_instance" "control" {
  ami                         = data.aws_ssm_parameter.ubuntu.value
  instance_type               = "t3.micro"
  subnet_id                   = aws_default_subnet.worker.id
  vpc_security_group_ids      = [aws_security_group.control.id]
  iam_instance_profile        = aws_iam_instance_profile.node["control"].name
  associate_public_ip_address = true

  root_block_device {
    volume_size           = 8
    volume_type           = "gp3"
    delete_on_termination = true
  }

  user_data                            = templatefile("${path.module}/node.sh.tftpl", merge(local.node_vars, { runners = "0" }))
  user_data_replace_on_change          = true
  instance_initiated_shutdown_behavior = "terminate"

  tags = {
    Name = "oj-control"
  }
}

# An auto-assigned public IP is lost when the box stops, so the address anything
# is pointed at is held apart from the instance.
resource "aws_eip" "control" {
  domain = "vpc"
}

resource "aws_eip_association" "control" {
  instance_id   = aws_instance.control.id
  allocation_id = aws_eip.control.id
}

output "region" {
  value = var.region
}

output "table" {
  value = aws_dynamodb_table.log.name
}

output "stream_arn" {
  value = aws_dynamodb_table.log.stream_arn
}

output "bucket" {
  value = aws_s3_bucket.ship.id
}

output "instance_ids" {
  value = aws_instance.worker[*].id
}

output "control_id" {
  value = aws_instance.control.id
}

output "api_url" {
  value = "http://${aws_eip.control.public_ip}:8080"
}

output "fis_template_ids" {
  value = aws_fis_experiment_template.kill[*].id
}

output "stop_template_id" {
  value = aws_fis_experiment_template.stop_worker.id
}

output "token" {
  value     = random_password.token.result
  sensitive = true
}

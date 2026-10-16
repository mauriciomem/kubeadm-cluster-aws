# Pins the computed attributes the configuration reads during plan; anything not
# listed here gets random values, which is fine as long as nothing parses it.
mock_data "aws_availability_zones" {
  defaults = {
    names = ["us-east-1a", "us-east-1b", "us-east-1c"]
  }
}

mock_data "aws_ec2_instance_type_offerings" {
  defaults = {
    locations = ["us-east-1a", "us-east-1b", "us-east-1c"]
  }
}

mock_data "aws_caller_identity" {
  defaults = {
    account_id = "123456789012"
  }
}

mock_data "aws_partition" {
  defaults = {
    partition = "aws"
  }
}

mock_data "aws_region" {
  defaults = {
    region = "us-east-1"
  }
}

mock_data "aws_ssm_parameter" {
  defaults = {
    insecure_value = "ami-0123456789abcdef0"
  }
}

mock_data "aws_iam_policy_document" {
  defaults = {
    json = "{}"
  }
}

mock_resource "aws_lb" {
  override_during = plan
  defaults = {
    arn      = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/net/kube-lab-test-api/0123456789abcdef"
    dns_name = "kube-lab-test-api-0123456789abcdef.elb.us-east-1.amazonaws.com"
  }
}

mock_resource "aws_lb_target_group" {
  override_during = plan
  defaults = {
    arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/kube-lab-test-api/0123456789abcdef"
  }
}

mock_resource "aws_iam_role" {
  override_during = plan
  defaults = {
    arn = "arn:aws:iam::123456789012:role/kube-lab-test"
  }
}

mock_resource "aws_iam_instance_profile" {
  override_during = plan
  defaults = {
    arn = "arn:aws:iam::123456789012:instance-profile/kube-lab-test"
  }
}

mock_resource "aws_eip" {
  override_during = plan
  defaults = {
    public_ip = "198.51.100.10"
  }
}

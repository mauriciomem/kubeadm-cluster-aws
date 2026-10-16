# Exercises modules/network directly: AZ selection by instance type offering.
mock_provider "aws" {
  source = "./tests/mocks"
}

variables {
  name           = "kube-lab-test"
  instance_types = ["t3.medium", "m7i.large"]
}

run "uses_three_azs_when_all_offer_the_types" {
  command = plan

  module {
    source = "./modules/network"
  }

  assert {
    condition     = output.azs == ["us-east-1a", "us-east-1b", "us-east-1c"]
    error_message = "Expected the first three AZs; got ${jsonencode(output.azs)}."
  }
}

run "skips_azs_missing_an_instance_type" {
  command = plan

  module {
    source = "./modules/network"
  }

  override_data {
    target = data.aws_availability_zones.available
    values = { names = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d", "us-east-1e"] }
  }

  override_data {
    target = data.aws_ec2_instance_type_offerings.node["t3.medium"]
    values = { locations = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d", "us-east-1e"] }
  }

  override_data {
    target = data.aws_ec2_instance_type_offerings.node["m7i.large"]
    values = { locations = ["us-east-1b", "us-east-1d", "us-east-1e"] }
  }

  assert {
    condition     = output.azs == ["us-east-1b", "us-east-1d", "us-east-1e"]
    error_message = "Only AZs offering every type may be used; got ${jsonencode(output.azs)}."
  }
}

run "fails_with_fewer_than_two_azs" {
  command = plan

  module {
    source = "./modules/network"
  }

  override_data {
    target = data.aws_ec2_instance_type_offerings.node["m7i.large"]
    values = { locations = ["us-east-1a"] }
  }

  expect_failures = [output.azs]
}

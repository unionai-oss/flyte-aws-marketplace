packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = ">= 1.3.0"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "instance_type" {
  type    = string
  default = "m6i.large"
}

variable "devbox_image" {
  type    = string
  default = "cr.flyte.org/flyteorg/flyte-devbox:latest"
}

variable "ami_name_prefix" {
  type    = string
  default = "flyte-devbox"
}

# Build network. The build instance needs a public subnet with internet egress
# (apt + image pulls). No default — these are account-specific, so pass them at
# build time. Discover a public subnet in the current account/region with:
#   SUBNET=$(aws ec2 describe-subnets --filters Name=map-public-ip-on-launch,Values=true \
#            --query 'Subnets[0].SubnetId' --output text)
#   VPC=$(aws ec2 describe-subnets --subnet-ids "$SUBNET" --query 'Subnets[0].VpcId' --output text)
#   packer build -var subnet_id="$SUBNET" -var vpc_id="$VPC" .
variable "subnet_id" {
  type = string
}

variable "vpc_id" {
  type = string
}

# Canonical Ubuntu 24.04 (noble), gp3, amd64 — matches the CFN template's AMI.
source "amazon-ebs" "flyte" {
  region                      = var.region
  instance_type               = var.instance_type
  ssh_username                = "ubuntu"
  vpc_id                      = var.vpc_id
  subnet_id                   = var.subnet_id
  associate_public_ip_address = true

  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
      virtualization-type = "hvm"
      root-device-type    = "ebs"
    }
    owners      = ["099720109477"] # Canonical
    most_recent = true
  }

  ami_name        = "${var.ami_name_prefix}-{{timestamp}}"
  ami_description = "Flyte 2 devbox - Docker + devbox image; auth enforced at the ALB (Cognito jwt-validation/authenticate-cognito) (Ubuntu 24.04)"

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name        = var.ami_name_prefix
    Project     = "flyte-devbox"
    BuildSource = "packer"
    BaseImage   = "{{ .SourceAMIName }}"
  }

  # Marketplace hygiene: enforce IMDSv2 on the build instance.
  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }
}

build {
  name    = "flyte-devbox"
  sources = ["source.amazon-ebs.flyte"]

  # Stage the baked product files (scripts, traefik manifest, systemd units).
  # No trailing slash + dest /tmp => uploads the dir as /tmp/files (unambiguous).
  provisioner "file" {
    source      = "files"
    destination = "/tmp"
  }

  provisioner "shell" {
    environment_vars = [
      "DEVBOX_IMAGE=${var.devbox_image}",
    ]
    execute_command = "chmod +x {{ .Path }}; sudo env {{ .Vars }} bash '{{ .Path }}'"
    script          = "provision.sh"
  }
}

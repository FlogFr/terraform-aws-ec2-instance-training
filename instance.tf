# https://aws.amazon.com/ec2/instance-types/
variable "type" {
  type = string
}

variable "name" {
  type = string
}

variable "packages" {
  type = list(string)
}

variable "ingresses" {
  type = list(object({protocol = number, port = number}))
}

# Search for the latest aws ami
# aws ec2 describe-images --owners amazon --filters "Name=description,Values=Debian 11*" "Name=architecture,Values=x86_64" "Name=virtualization-type,Values=hvm"
data "aws_ami" "debian" {
  most_recent = true
  name_regex  = "debian-11-amd64-*"
  owners      = ["amazon"]

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Now install VPC - VMs
resource "aws_vpc" "main" {
  cidr_block = "172.16.0.0/16"
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

resource "aws_default_route_table" "main" {
  default_route_table_id = aws_vpc.main.default_route_table_id

  # Default route to local is always present

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  route {
    ipv6_cidr_block = "::/0"
    gateway_id      = aws_internet_gateway.main.id
  }
}

resource "aws_subnet" "submain" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "172.16.10.0/24"
}

resource "aws_default_network_acl" "main" {
  default_network_acl_id = aws_vpc.main.default_network_acl_id

  dynamic "ingress" {
    for_each = var.ingresses

    content {
      protocol   = ingress.value["protocol"]
      rule_no    = sum([100, ingress.value["port"]])
      action     = "allow"
      cidr_block = "0.0.0.0/0"
      from_port  = ingress.value["port"]
      to_port    = ingress.value["port"]
    }
  }

  egress {
    protocol   = -1
    rule_no    = 100
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  egress {
    protocol        = -1
    rule_no         = 101
    action          = "allow"
    ipv6_cidr_block = "::/0"
    from_port       = 0
    to_port         = 0
  }

  lifecycle {
    ignore_changes = [subnet_ids]
  }
}

resource "aws_network_interface" "vm" {
  subnet_id   = aws_subnet.submain.id
  private_ips = ["172.16.10.100"]

  tags = {
    Name = "primary_network_interface"
  }
}

locals {
  listpackages = join("\n", formatlist(" - %s", var.packages))
}

resource "aws_instance" "vm" {
  ami           = data.aws_ami.debian.id
  instance_type = var.type

  network_interface {
    network_interface_id = aws_network_interface.vm.id
    device_index         = 0
  }

  tags = {
    Name = "Debian ${var.name}"
  }

  user_data = <<EOF
#cloud-config
repo_update: true
repo_upgrade: all

packages:
${local.listpackages}

write_files:
  - path: /tmp/index.html
    permissions: '0755'
    content: |
      <!DOCTYPE html>
      <html>
      <head>
      <title>TP4 - 1 Success</title>
      </head>
      <body>
      <h1>TP4 - 1 Success</h1>
      <h2>Let's move on</h2>
      </body>
      </html>
  - path: /usr/local/bin/provision.sh
    permissions: '0755'
    content: |
      #!/bin/bash

      # Update SSH for Password Authentication
      echo -e "Host *\n    PasswordAuthentication yes" > /etc/ssh/ssh_config.d/passwd.conf

      # Update Sudo for User without passwd
      echo -e "# User rules for trainee\ntrainee ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/90-cloud-init-users
      sed -i -E 's/#?PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
      systemctl restart ssh

      # Add user with passwd
      useradd -G sudo -s /bin/bash -m trainee
      echo "trainee:trainee" | chpasswd 

      rm /var/www/html/index.nginx-debian.html
      mv /tmp/index.html /var/www/html/index.html

runcmd:
  - [bash, /usr/local/bin/provision.sh]
EOF
}

resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id

  dynamic "ingress" {
    for_each = var.ingresses

    content {
      protocol  = ingress.value["protocol"]
      from_port = ingress.value["port"]
      to_port   = ingress.value["port"]
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_eip" "main" {
  vpc        = true
  depends_on = [aws_internet_gateway.main]
}

# Associate EIP with EC2 Instance
resource "aws_eip_association" "main" {
  instance_id   = aws_instance.vm.id
  allocation_id = aws_eip.main.id
}

output "vm" {
  value = aws_instance.vm
}

output "eip" {
  value = aws_eip.main
}

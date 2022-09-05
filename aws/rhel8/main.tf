provider "aws" {
  profile = "default"
  region = "us-east-1"
}

resource "aws_instance" "vm" {
  # rhel8 ami-0b0af3577fe5e3532 free tier
  ami = "ami-0b0af3577fe5e3532"
  # Use subnet id if not using default profile
  # subnet_id = "<insert subnet id>"
  
  # 2 vCPU 4 GB RAM
  instance_type = "t2.medium"

  # Use tags to distinguish EC2 instance
  tags = {
      Name = "aim-aws-tf-node"
  }

}
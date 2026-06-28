data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "tls_private_key" "bastion" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "bastion" {
  key_name   = "skills-book-bastion"
  public_key = tls_private_key.bastion.public_key_openssh
}

resource "local_file" "bastion_key" {
  content         = tls_private_key.bastion.private_key_pem
  filename        = "${path.module}/bastion-key.pem"
  file_permission = "0600"
}

resource "aws_iam_role" "bastion" {
  name = "skills-book-bastion-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "bastion_ecr" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "skills-book-bastion-profile"
  role = aws_iam_role.bastion.name
}

resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.all.id]
  iam_instance_profile   = aws_iam_instance_profile.bastion.name
  key_name               = aws_key_pair.bastion.key_name

  depends_on = [aws_internet_gateway.main, aws_ecr_repository.book]

  connection {
    type        = "ssh"
    user        = "ec2-user"
    private_key = tls_private_key.bastion.private_key_pem
    host        = self.public_ip
    timeout     = "5m"
  }

  provisioner "file" {
    source      = "${path.module}/app"
    destination = "/tmp/app"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo dnf install -y docker",
      "sudo systemctl start docker",
      "aws ecr get-login-password --region ap-northeast-2 | sudo docker login --username AWS --password-stdin ${data.aws_caller_identity.current.account_id}.dkr.ecr.ap-northeast-2.amazonaws.com",
      "sudo docker build -t skills-book-app /tmp/app",
      "sudo docker tag skills-book-app:latest ${aws_ecr_repository.book.repository_url}:latest",
      "sudo docker push ${aws_ecr_repository.book.repository_url}:latest"
    ]
  }

  tags = { Name = "skills-book-bastion" }
}

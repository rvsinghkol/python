output "state_bucket" {
  description = "Put this in terraform/app/versions.tf -> backend \"s3\" -> bucket"
  value       = aws_s3_bucket.tfstate.bucket
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "jenkins_iam_user" {
  description = "Create an access key for this user and store it in Jenkins (README Step 2)"
  value       = aws_iam_user.jenkins.name
}

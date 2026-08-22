# The secret container only. Its VALUE is set out of band so a database
# password never appears in terraform state (day 61) or in git.
resource "aws_secretsmanager_secret" "postgres" {
  name        = var.postgres_secret_name
  description = "DevBoard in-cluster Postgres credentials"

  # 0 = delete immediately. The 30-day default recovery window blocks
  # recreating a secret with the same name for a month after destroy,
  # which makes teardown-and-rebuild painful on a learning account.
  recovery_window_in_days = 0

  tags = local.tags
}

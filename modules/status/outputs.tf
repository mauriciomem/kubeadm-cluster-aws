output "message" {
  description = "What the cluster_ready check prints when the cluster isn't ready: the statuses, or the node and step that failed."
  value       = local.message
}

output "status" {
  description = "Status values keyed by \"cluster\" and by node name. \"unreadable\" for a SecureString, \"invalid\" for a value that isn't a status."
  value       = local.status
}

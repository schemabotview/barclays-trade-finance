# Pins job and interactive clusters to one single-node VM that fits the 4-vCPU quota.

terraform {
  required_providers {
    databricks = { source = "databricks/databricks" }
  }
}

variable "name" { type = string }
variable "node_type" { type = string }
variable "autotermination_minutes" { type = number }

resource "databricks_cluster_policy" "this" {
  name = var.name
  definition = jsonencode({
    "node_type_id"                                = { type = "fixed", value = var.node_type }
    "driver_node_type_id"                         = { type = "fixed", value = var.node_type }
    "num_workers"                                 = { type = "fixed", value = 0 }
    "autotermination_minutes"                     = { type = "fixed", value = var.autotermination_minutes }
    "data_security_mode"                          = { type = "fixed", value = "SINGLE_USER" }
    "spark_conf.spark.master"                     = { type = "fixed", value = "local[*, 4]" }
    "spark_conf.spark.databricks.cluster.profile" = { type = "fixed", value = "singleNode" }
    "custom_tags.ResourceClass"                   = { type = "fixed", value = "SingleNode" }
  })
}

output "id" { value = databricks_cluster_policy.this.id }

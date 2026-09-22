variable "kubeconfig" {
  description = "Path to the kubeconfig file used to access Harvester."
  type        = string
  default     = "~/.kube/harvester.yaml"
}

variable "kubecontext" {
  description = "Kubernetes context used to access Harvester."
  type        = string
  default     = null
  nullable    = true
}

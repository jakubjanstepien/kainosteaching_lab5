variable "instance" {
  type        = string
  default     = "dev"
  description = "The unique instance identifier for this resource"
}

variable "release_version" {
  type        = string
  description = "A release version string that is added as a tag to provisioned resources."
}
locals {
  tags = {
    environment = var.instance
    source      = "kainosteaching_lab5"
    provisioner = "terraform"
    version     = var.release_version
    # App specific tags
    criticality = "Tier 5"
    OwnerName   = "ZSP"
    org         = "ZSP"
    application = "Lab_5"
  }
  acr_name = "acrzsp"
  service_prefix = "jjs"
  # service_prefix = "lab3-CHG ME!"
}

module "service" {
  source                   = "../../src"
  name                     = local.service_prefix
  instance                 = var.instance
  app_service_tier             = "Basic"
  acr_name = local.acr_name
  tags                     = local.tags
}
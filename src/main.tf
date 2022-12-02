resource "azurerm_resource_group" "resource_group" {
  name     = format("rg-%s-%s", var.name, var.instance)
  location = var.location
  tags     = var.tags
}

resource "azurerm_app_service_plan" "basic" {
  name                = "example-appserviceplan"
  location            = azurerm_resource_group.resource_group.location
  resource_group_name = azurerm_resource_group.resource_group.name
  kind                = "Linux"
  reserved            = true

  sku {
    tier = "Basic"
    size = "B1"
  }
}

resource "azurerm_app_service" "app_service" {
  name                = "zsplab5"
  location            = azurerm_resource_group.resource_group.location
  resource_group_name = azurerm_resource_group.resource_group.name
  app_service_plan_id = azurerm_app_service_plan.basic.id

  site_config {
      # linux_fx_version = "DOCKER|web/${var.acr_name}:latest"
      linux_fx_version = "DOCKER|web/zsp-lab5-ost:latest"
      # acr_use_managed_identity_credentials = true
      # container_registry_managed_identity_client_id = azurerm_user_assigned_identity.aui
  }

  app_settings = {
    DOCKER_REGISTRY_SERVER_URL = "https://${var.acr_name}.azurecr.io"
    DOCKER_REGISTRY_SERVER_USERNAME = "acrzsp"
    DOCKER_REGISTRY_SERVER_PASSWORD = "mELyYn6Zunf0Sp+TwaafjaM0Ktmv1Pva"
  }

  identity {
      type = "SystemAssigned"
      # identity_ids = azurerm_user_assigned_identity.aui.principal_id
  } 
}

# resource "azurerm_user_assigned_identity" "aui" {
#   location            = azurerm_resource_group.resource_group.location
#   name                = "ami_zsp_lab5_acr"
#   resource_group_name = azurerm_resource_group.resource_group.name
# }

data "azurerm_container_registry" "acr" {
  name                = var.acr_name
  # name                = "acrzsp"
  # resource_group_name = local.resource_group_name
  resource_group_name = "rg-acr-tst"
}

resource "azurerm_role_assignment" "identity" {
  # name = "ars"
  role_definition_name = "AcrPull"
  scope                = data.azurerm_container_registry.acr.id
  principal_id         = azurerm_app_service.app_service.identity[0].principal_id
}
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "2.98.0"
    }
  }
  backend "azurerm" {
    resource_group_name  = "rg-tfstate-tst"
    storage_account_name = "zsptfstatetst"
    container_name       = "tfstate"
    key                  = "lab5.dev.tfstate"
  }
}

provider "azurerm" {
  # Provided via envvars or user authed via az login
  features {}
}

terraform {
  backend "azurerm" {}
  required_providers {
    azurerm = {
      source  = "Hashicorp/azurerm"
      version = "4.60.0"
    }
  }
}

terraform {
  backend "azurerm" {
    key = "terraform.tfstate"
  }
  required_providers {
    azurerm = {
      source  = "Hashicorp/azurerm"
      version = "4.60.0"
    }
  }
}

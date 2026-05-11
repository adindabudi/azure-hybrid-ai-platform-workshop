terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.54"
    }
  }
}

variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "vnet_name" { type = string }
variable "tags" { type = map(string) }

variable "address_space" {
  type    = string
  default = "10.40.0.0/16"
}

# Subnet plan (per workshop plan §2.2)
locals {
  subnets = {
    apim    = "10.40.1.0/24"
    aks     = "10.40.4.0/22"  # 1024 IPs — generous for 10 attendees with sidecars
    pe      = "10.40.8.0/24"  # private endpoints
    bastion = "10.40.9.0/26"  # AzureBastionSubnet (must be /26 minimum)
    appgw   = "10.40.10.0/24" # reserved for future
  }
}

resource "azurerm_virtual_network" "this" {
  name                = var.vnet_name
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = [var.address_space]
  tags                = var.tags
}

resource "azurerm_subnet" "this" {
  for_each = local.subnets

  name                 = "snet-${each.key}"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [each.value]

  # AKS subnet must NOT delegate; PE subnet needs network policies; APIM has its own NSG rules.
  private_endpoint_network_policies             = each.key == "pe" ? "Disabled" : "Enabled"
  private_link_service_network_policies_enabled = true
}

# AzureBastionSubnet must be named exactly that. We override.
resource "azurerm_subnet" "bastion_alias" {
  count                = 0 # disabled — bastion is optional, leave snet-bastion in place
  name                 = "AzureBastionSubnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.40.9.0/26"]
}

# NSG for AKS subnet — outbound only restrictions; default rules allow internal.
resource "azurerm_network_security_group" "aks" {
  name                = "nsg-aks"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_subnet_network_security_group_association" "aks" {
  subnet_id                 = azurerm_subnet.this["aks"].id
  network_security_group_id = azurerm_network_security_group.aks.id
}

# NSG for APIM subnet — public docs require these rules even for self-managed VNet integration scenarios;
# for Developer SKU with no external VNet, this is harmless and future-proofs the migration to Premium.
resource "azurerm_network_security_group" "apim" {
  name                = "nsg-apim"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  security_rule {
    name                       = "AllowAPIMManagement"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3443"
    source_address_prefix      = "ApiManagement"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "AllowAzureLoadBalancer"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "6390"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "VirtualNetwork"
  }
}

resource "azurerm_subnet_network_security_group_association" "apim" {
  subnet_id                 = azurerm_subnet.this["apim"].id
  network_security_group_id = azurerm_network_security_group.apim.id
}

output "vnet_id" {
  value = azurerm_virtual_network.this.id
}

output "vnet_name" {
  value = azurerm_virtual_network.this.name
}

output "subnet_ids" {
  value = { for k, v in azurerm_subnet.this : k => v.id }
}

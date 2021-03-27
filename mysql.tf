terraform {
  required_version = ">= 0.13"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 2.26"
    }
  }
}

provider "azurerm" {
  skip_provider_registration = true
  features {}
}

resource "azurerm_resource_group" "ntpnatividademysql" {
    name     = "ntpnatividademysql"
    location = "eastus"

    tags     = {
        "Environment" = "ntpnatividademysql"
    }
}

resource "azurerm_virtual_network" "vnmysql" {
    name                = "vnmysql"
    address_space       = ["10.0.0.0/16"]
    location            = "eastus"
    resource_group_name = azurerm_resource_group.ntpnatividademysql.name
}

resource "azurerm_subnet" "subnetmysql" {
    name                 = "subnetmysql"
    resource_group_name  = azurerm_resource_group.ntpnatividademysql.name
    virtual_network_name = azurerm_virtual_network.vnmysql.name
    address_prefixes       = ["10.0.1.0/24"]
}

resource "azurerm_public_ip" "ippublicmysql" {
    name                         = "ippublicmysql"
    location                     = "eastus"
    resource_group_name          = azurerm_resource_group.ntpnatividademysql.name
    allocation_method            = "Static"
}

resource "azurerm_network_security_group" "nsgmysql" {
    name                = "nsgmysql"
    location            = "eastus"
    resource_group_name = azurerm_resource_group.ntpnatividademysql.name

    security_rule {
        name                       = "mysql"
        priority                   = 1001
        direction                  = "Inbound"
        access                     = "Allow"
        protocol                   = "Tcp"
        source_port_range          = "*"
        destination_port_range     = "3306"
        source_address_prefix      = "*"
        destination_address_prefix = "*"
    }

    security_rule {
        name                       = "SSH"
        priority                   = 1002
        direction                  = "Inbound"
        access                     = "Allow"
        protocol                   = "Tcp"
        source_port_range          = "*"
        destination_port_range     = "22"
        source_address_prefix      = "*"
        destination_address_prefix = "*"
    }
}

resource "azurerm_network_interface" "nicmysql" {
    name                      = "nicmysql"
    location                  = "eastus"
    resource_group_name       = azurerm_resource_group.ntpnatividademysql.name

    ip_configuration {
        name                          = "myNicConfiguration"
        subnet_id                     = azurerm_subnet.subnetmysql.id
        private_ip_address_allocation = "Dynamic"
        public_ip_address_id          = azurerm_public_ip.ippublicmysql.id
    }
}

resource "azurerm_network_interface_security_group_association" "example" {
    network_interface_id      = azurerm_network_interface.nicmysql.id
    network_security_group_id = azurerm_network_security_group.nsgmysql.id
}

data "azurerm_public_ip" "ip_publico" {
  name                = azurerm_public_ip.ippublicmysql.name
  resource_group_name = azurerm_resource_group.ntpnatividademysql.name
}

resource "azurerm_storage_account" "accountstorage" {
    name                        = "storageaccountmysql"
    resource_group_name         = azurerm_resource_group.ntpnatividademysql.name
    location                    = "eastus"
    account_tier                = "Standard"
    account_replication_type    = "LRS"
}

resource "azurerm_linux_virtual_machine" "vmmysql" {
    name                  = "virtualmysql"
    location              = "eastus"
    resource_group_name   = azurerm_resource_group.ntpnatividademysql.name
    network_interface_ids = [azurerm_network_interface.nicmysql.id]
    size                  = "Standard_DS1_v2"

    os_disk {
        name              = "MySQLDisk"
        caching           = "ReadWrite"
        storage_account_type = "Premium_LRS"
    }

    source_image_reference {
        publisher = "Canonical"
        offer     = "UbuntuServer"
        sku       = "18.04-LTS"
        version   = "latest"
    }

    computer_name  = "myvm"
    admin_username = var.user
    admin_password = var.password
    disable_password_authentication = false

    boot_diagnostics {
        storage_account_uri = azurerm_storage_account.accountstorage.primary_blob_endpoint
    }

    depends_on = [ azurerm_resource_group.ntpnatividademysql ]
}

output "public_ip_address_mysql" {
  value = azurerm_public_ip.ippublicmysql.ip_address
}

resource "time_sleep" "wait_30_seconds_db" {
  depends_on = [azurerm_linux_virtual_machine.vmmysql]
  create_duration = "30s"
}

resource "null_resource" "upload_db" {
    provisioner "file" {
        connection {
            type = "ssh"
            user = var.user
            password = var.password
            host = data.azurerm_public_ip.ip_publico.ip_address
        }
        source = "config"
        destination = "/home/azmysql"
    }

    depends_on = [ time_sleep.wait_30_seconds_db ]
}

resource "null_resource" "deploy_db" {
    triggers = {
        order = null_resource.upload_db.id
    }
    provisioner "remote-exec" {
        connection {
            type = "ssh"
            user = var.user
            password = var.password
            host = data.azurerm_public_ip.ip_publico.ip_address
        }
        inline = [
            "sudo apt-get update",
            "sudo apt-get install -y mysql-server-5.7",
            "sudo mysql < /home/azmysql/config/user.sql",
            "sudo cp -f /home/azmysql/config/mysqld.cnf /etc/mysql/mysql.conf.d/mysqld.cnf",
            "sudo service mysql restart",
            "sleep 20",
        ]
    }
}

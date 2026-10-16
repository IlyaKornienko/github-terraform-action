#!/usr/bin/env bash
#
# Creates the Azure resources required to store Terraform remote state, plus a
# User-Assigned Managed Identity (UAMI) with a GitHub Actions federated
# credential so workflows can authenticate via OIDC (no secrets).
#
# Resources created:
#   - Resource group
#   - Storage account + blob container (for tf state)
#   - User-assigned managed identity
#   - Federated identity credential (GitHub OIDC) on the UAMI
#   - Role assignments:
#       * Storage Blob Data Contributor on the storage account (for tf state)
#       * Contributor on the subscription (so Terraform can manage resources)
#
# Usage:
#   GITHUB_REPO=owner/repo ./scripts/create-tf-backend.sh
#
# Override defaults via environment variables, e.g.:
#   RESOURCE_GROUP=my-tfstate-rg LOCATION=westus2 \
#   GITHUB_REPO=myorg/myrepo GITHUB_ENVIRONMENT=terraform-plan \
#   ./scripts/create-tf-backend.sh

set -euo pipefail

# ----- Configuration (override via env vars) ----------------------------------
RESOURCE_GROUP="${RESOURCE_GROUP:-tfstate-rg}"
LOCATION="${LOCATION:-swedencentral}"
# Storage account names must be globally unique, 3-24 lowercase alphanumeric chars.
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:-tfstate$RANDOM$RANDOM}"
CONTAINER_NAME="${CONTAINER_NAME:-tfstate}"
SKU="${SKU:-Standard_LRS}"

# Managed identity / GitHub OIDC config
UAMI_NAME="${UAMI_NAME:-tfstate-github-uami}"
GITHUB_REPO="${GITHUB_REPO:-}"                       # e.g. "owner/repo" (REQUIRED)
PLAN_ENVIRONMENT="${PLAN_ENVIRONMENT:-terraform-plan}"
APPLY_ENVIRONMENT="${APPLY_ENVIRONMENT:-terraform-apply}"
SUBSCRIPTION_ROLE="${SUBSCRIPTION_ROLE:-Contributor}"

# ----- Preflight --------------------------------------------------------------
if ! command -v az >/dev/null 2>&1; then
  echo "ERROR: Azure CLI ('az') is not installed. See https://aka.ms/azcli" >&2
  exit 1
fi

if ! az account show >/dev/null 2>&1; then
  echo "ERROR: Not logged in to Azure. Run 'az login' first." >&2
  exit 1
fi

if [[ -z "${GITHUB_REPO}" ]]; then
  echo "ERROR: GITHUB_REPO env var is required (e.g. 'owner/repo')." >&2
  exit 1
fi

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"

PLAN_SUBJECT="repo:${GITHUB_REPO}:environment:${PLAN_ENVIRONMENT}"
APPLY_SUBJECT="repo:${GITHUB_REPO}:environment:${APPLY_ENVIRONMENT}"

echo "Subscription : $(az account show --query name -o tsv) (${SUBSCRIPTION_ID})"
echo "Tenant       : ${TENANT_ID}"
echo "Resource grp : ${RESOURCE_GROUP}"
echo "Location     : ${LOCATION}"
echo "Storage acct : ${STORAGE_ACCOUNT}"
echo "Container    : ${CONTAINER_NAME}"
echo "UAMI         : ${UAMI_NAME}"
echo "OIDC subjects:"
echo "  - ${PLAN_SUBJECT}"
echo "  - ${APPLY_SUBJECT}"
echo

# ----- Resource group ---------------------------------------------------------
echo "==> Creating resource group..."
az group create \
  --name "${RESOURCE_GROUP}" \
  --location "${LOCATION}" \
  --output none

# ----- Storage account --------------------------------------------------------
echo "==> Creating storage account..."
az storage account create \
  --name "${STORAGE_ACCOUNT}" \
  --resource-group "${RESOURCE_GROUP}" \
  --location "${LOCATION}" \
  --sku "${SKU}" \
  --kind StorageV2 \
  --encryption-services blob \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  --public-network-access Enabled \
  --default-action Allow \
  --output none

STORAGE_ACCOUNT_ID="$(az storage account show \
  --name "${STORAGE_ACCOUNT}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query id -o tsv)"

# ----- Blob container ---------------------------------------------------------
echo "==> Creating blob container..."
az storage container create \
  --name "${CONTAINER_NAME}" \
  --account-name "${STORAGE_ACCOUNT}" \
  --auth-mode login \
  --output none

# ----- User-assigned managed identity ----------------------------------------
echo "==> Creating user-assigned managed identity..."
az identity create \
  --name "${UAMI_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --location "${LOCATION}" \
  --output none

UAMI_CLIENT_ID="$(az identity show \
  --name "${UAMI_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query clientId -o tsv)"
UAMI_PRINCIPAL_ID="$(az identity show \
  --name "${UAMI_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query principalId -o tsv)"

# ----- Federated credentials (GitHub OIDC) -----------------------------------
echo "==> Creating federated credential for '${PLAN_ENVIRONMENT}' environment..."
az identity federated-credential create \
  --name "github-${PLAN_ENVIRONMENT}" \
  --identity-name "${UAMI_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --issuer "https://token.actions.githubusercontent.com" \
  --subject "${PLAN_SUBJECT}" \
  --audiences "api://AzureADTokenExchange" \
  --output none

echo "==> Creating federated credential for '${APPLY_ENVIRONMENT}' environment..."
az identity federated-credential create \
  --name "github-${APPLY_ENVIRONMENT}" \
  --identity-name "${UAMI_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --issuer "https://token.actions.githubusercontent.com" \
  --subject "${APPLY_SUBJECT}" \
  --audiences "api://AzureADTokenExchange" \
  --output none

# ----- Role assignments ------------------------------------------------------
echo "==> Assigning 'Storage Blob Data Contributor' on storage account..."
az role assignment create \
  --assignee-object-id "${UAMI_PRINCIPAL_ID}" \
  --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" \
  --scope "${STORAGE_ACCOUNT_ID}" \
  --output none

echo "==> Assigning '${SUBSCRIPTION_ROLE}' on subscription..."
az role assignment create \
  --assignee-object-id "${UAMI_PRINCIPAL_ID}" \
  --assignee-principal-type ServicePrincipal \
  --role "${SUBSCRIPTION_ROLE}" \
  --scope "/subscriptions/${SUBSCRIPTION_ID}" \
  --output none

# ----- Output -----------------------------------------------------------------
cat <<EOF

Done.

GitHub Actions variables to configure for repo '${GITHUB_REPO}':
  AZURE_CLIENT_ID       = ${UAMI_CLIENT_ID}
  AZURE_TENANT_ID       = ${TENANT_ID}
  AZURE_SUBSCRIPTION_ID = ${SUBSCRIPTION_ID}

Terraform backend block:

  terraform {
    backend "azurerm" {
      resource_group_name  = "${RESOURCE_GROUP}"
      storage_account_name = "${STORAGE_ACCOUNT}"
      container_name       = "${CONTAINER_NAME}"
      key                  = "terraform.tfstate"
    }
  }

azure/login@v2 step:

  - uses: azure/login@v2
    with:
      client-id: \${{ vars.AZURE_CLIENT_ID }}
      tenant-id: \${{ vars.AZURE_TENANT_ID }}
      subscription-id: \${{ vars.AZURE_SUBSCRIPTION_ID }}
EOF
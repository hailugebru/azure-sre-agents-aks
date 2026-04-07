# ============================================================
# Step 1 - Prerequisites
#   Register the NAP preview feature and install the CLI extension
# ============================================================
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\00-variables.ps1"

# Select the target subscription
az account set -s $SUBSCRIPTION_ID
az account show -o table

# Enable the NAP preview feature (may take a few minutes)
az feature register `
  --namespace "Microsoft.ContainerService" `
  --name "NodeAutoProvisioningPreview"

Write-Host "Waiting for feature registration..." -ForegroundColor Yellow
do {
    $state = az feature show `
      --namespace "Microsoft.ContainerService" `
      --name "NodeAutoProvisioningPreview" `
      --query "properties.state" -o tsv
    Write-Host "  RegistrationState: $state"
    if ($state -ne "Registered") { Start-Sleep -Seconds 30 }
} while ($state -ne "Registered")

# Refresh the provider registration
az provider register --namespace Microsoft.ContainerService

# Install / update the aks-preview CLI extension
az extension add --name aks-preview 2>$null
if ($LASTEXITCODE -ne 0) {
    az extension update --name aks-preview
}

Write-Host "Prerequisites complete." -ForegroundColor Green

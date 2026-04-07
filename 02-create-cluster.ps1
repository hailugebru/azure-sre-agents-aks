# ============================================================
# Step 2 - Create the AKS cluster
#   NAP enabled, Azure CNI Overlay with Cilium
# ============================================================
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\00-variables.ps1"

# Create resource group
az group create -n $RESOURCE_GROUP -l $LOCATION

# Create AKS cluster (this takes several minutes)
Write-Host "Creating AKS cluster '$CLUSTER_NAME'... this takes several minutes." -ForegroundColor Yellow
az aks create `
  --name $CLUSTER_NAME `
  --resource-group $RESOURCE_GROUP `
  --node-provisioning-mode Auto `
  --network-plugin azure `
  --network-plugin-mode overlay `
  --network-dataplane cilium `
  --generate-ssh-keys

# Get cluster credentials
az aks get-credentials -g $RESOURCE_GROUP -n $CLUSTER_NAME

Write-Host "Cluster created and kubeconfig configured." -ForegroundColor Green

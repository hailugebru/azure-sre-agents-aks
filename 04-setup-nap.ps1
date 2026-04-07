# ============================================================
# Step 4 - Taint the system node pool so NAP provisions user nodes
# ============================================================
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\00-variables.ps1"

# Discover the default (system) nodepool name
$defaultNodepoolName = az aks nodepool list `
  -g $RESOURCE_GROUP `
  --cluster-name $CLUSTER_NAME `
  --query '[0].name' -o tsv

Write-Host "Default nodepool: $defaultNodepoolName" -ForegroundColor Yellow

# Apply the CriticalAddonsOnly taint (NoExecute will evict non-tolerated pods)
az aks nodepool update `
  -g $RESOURCE_GROUP `
  --cluster-name $CLUSTER_NAME `
  -n $defaultNodepoolName `
  --node-taints CriticalAddonsOnly=true:NoExecute

Write-Host ""
Write-Host "Taint applied. NAP will now create user-mode nodes." -ForegroundColor Green
Write-Host ""
Write-Host "--- Monitor with ---" -ForegroundColor Cyan
Write-Host "  kubectl get events -A --field-selector source=karpenter -w"
Write-Host "  kubectl get nodes,pods -n pets -o wide -w"
Write-Host ""
Write-Host "--- Inspect existing NAP nodepools ---" -ForegroundColor Cyan
Write-Host "  kubectl get nodepool"
Write-Host "  kubectl describe nodepool default"
Write-Host "  kubectl describe nodepool system-surge"

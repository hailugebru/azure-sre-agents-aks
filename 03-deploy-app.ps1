# ============================================================
# Step 3 - Deploy the AKS Store demo application
# ============================================================
$ErrorActionPreference = "Stop"
$appManifestsDir = Join-Path $PSScriptRoot "manifests\aks-store"

# Create the namespace
kubectl create ns pets --dry-run=client -o yaml | kubectl apply -f -

# Deploy the pet store from the local manifests folder
kubectl apply -f $appManifestsDir -n pets

Write-Host "Waiting for all pods to be Ready..." -ForegroundColor Yellow
kubectl wait --for=condition=Ready pod --all -n pets --timeout=300s

# Check deployment status
kubectl get all -n pets

# Print the store URL
$storeIp = kubectl get svc store-front -n pets -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
Write-Host ""
Write-Host "Pet Store URL: http://$storeIp" -ForegroundColor Cyan

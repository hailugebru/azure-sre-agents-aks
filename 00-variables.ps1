# ============================================================
# Shared environment variables for the NAP (Karpenter) demo
# Dot-source this file before running any other script:
#   . .\00-variables.ps1
# ============================================================

# Azure
$SUBSCRIPTION_ID = "dd2c8f4a-2b44-45a8-9e39-52e667cbd854"  # <-- replace
$RESOURCE_GROUP  = "Azure-SRE-Agent-Demo_RG"
$LOCATION        = "canadacentral"
$CLUSTER_NAME    = "Azure-SRE-Agent-Demo-Cluster"
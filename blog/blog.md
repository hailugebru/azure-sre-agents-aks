# Autonomous AKS Incident Response with Azure SRE Agent

**Published:** April 7, 2026 &nbsp;|&nbsp; **Author:** Hailu Gebru, Product Manager — Azure SRE Agent &nbsp;|&nbsp; **Read time:** 15 min  
**Tags:** AKS, Azure SRE Agent, AI Ops, Node Auto-Provisioning, KEDA, Incident Response

---

## In This Article

1. [Introduction — The Problem Azure SRE Agent Solves](#introduction)
2. [Solution Architecture](#solution-architecture)
3. [Prerequisites & Demo Repo](#prerequisites--demo-repo)
4. [Step 1 — Deploy an AKS Cluster with NAP](#step-1--deploy-an-aks-cluster-with-nap)
5. [Step 2 — Deploy the AKS Store Demo App](#step-2--deploy-the-aks-store-demo-app)
6. [Step 3 — Configure Azure SRE Agent](#step-3--configure-azure-sre-agent)
7. [Step 4 — See It in Action: Autonomous OOMKilled Recovery](#step-4--see-it-in-action-autonomous-oomkilled-recovery)
8. [Bonus: Node Auto-Provisioning in Action](#bonus-node-auto-provisioning-in-action)
9. [Next Steps & Resources](#next-steps--resources)

---

## Introduction

It's 2 AM. Azure Monitor fires a Sev1 alert: pods are crashing in your production AKS cluster. The traditional playbook kicks in — an on-call engineer is paged, logs in, runs a series of diagnostic commands, figures out the root cause, applies a fix, and verifies recovery. By the time that's done, **30 to 60 minutes have passed**.

For teams running containerized workloads on Azure Kubernetes Service (AKS), this manual response cycle is a source of alert fatigue, slow recovery times, and inconsistent remediation quality. **Azure SRE Agent** addresses this head-on: it is an AI-powered operations agent that connects to your Azure resources, receives alerts from Azure Monitor, and executes a structured investigate-diagnose-remediate-verify loop — fully autonomously.

In this post, I'll walk through the complete end-to-end experience: spinning up an AKS cluster with Node Auto-Provisioning (NAP), deploying a realistic demo application, wiring up Azure SRE Agent, and triggering a real OOMKilled incident so you can see the agent resolve it in real time.

| Metric | Result |
|---|---|
| Alert to Full Recovery | **< 2 minutes** |
| Human Interventions Required | **0** |
| Pods Recovered Automatically | **100%** |

---

## Solution Architecture

The demo environment brings together three layers: the AKS cluster (with NAP/Karpenter for intelligent node provisioning), the AKS Store Demo application, and the Azure SRE Agent wired to Azure Monitor.

```
Azure Monitor  →  Action Group  →  Azure SRE Agent  →  AKS Cluster
(Metric alert)    (Webhook)        (Investigate +       (NAP + Cilium
                                    Fix + Verify)         + KEDA)
```

| Component | Technology | Purpose |
|---|---|---|
| Cluster networking | Azure CNI Overlay + Cilium dataplane | eBPF-based networking; no kube-proxy |
| Node provisioning | NAP / Karpenter | Automatically provisions right-sized nodes |
| Autoscaling | KEDA | Scales `virtual-worker` on RabbitMQ queue depth |
| Monitoring trigger | Azure Monitor metric alert | Fires on unhealthy pod count > 0 |
| AI agent | Azure SRE Agent | Autonomous incident investigation and remediation |

---

## Prerequisites & Demo Repo

> **📦 Demo Repository:** [github.com/hailugebru/azure-sre-agents-aks](https://github.com/hailugebru/azure-sre-agents-aks)  
> PowerShell scripts, Kubernetes manifests, and KEDA ScaledObject configurations.

**You will need:**

- An Azure subscription with permission to create AKS clusters
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) (v2.56+) with the `aks-preview` extension
- [kubectl](https://kubernetes.io/docs/tasks/tools/) and PowerShell 7+
- Azure SRE Agent access (currently in preview — see the [docs](https://learn.microsoft.com/azure/sre-agent/) to request access)

```powershell
git clone https://github.com/hailugebru/azure-sre-agents-aks
cd azure-sre-agents-aks

# Edit your subscription ID before running any scripts
notepad 00-variables.ps1
```

---

## Step 1 — Deploy an AKS Cluster with NAP

The cluster is configured with **Node Auto-Provisioning (NAP)** — AKS's Karpenter-based node provisioner — combined with Azure CNI Overlay and the Cilium eBPF dataplane.

### Register the preview feature and create the cluster

```powershell
# Load shared variables into your session
. .\00-variables.ps1

# Register preview features and install aks-preview extension (~5-15 min)
.\01-prerequisites.ps1

# Create the cluster (~5-10 minutes)
.\02-create-cluster.ps1
```

The cluster creation command under the hood:

```bash
az aks create \
  --name "Azure-SRE-Agent-Demo-Cluster" \
  --resource-group "Azure-SRE-Agent-Demo_RG" \
  --node-provisioning-mode Auto \       # enables NAP/Karpenter
  --network-plugin azure \
  --network-plugin-mode overlay \
  --network-dataplane cilium \          # eBPF — no kube-proxy
  --generate-ssh-keys
```

> **💡 Why Cilium?**  
> The `--network-dataplane cilium` flag replaces the legacy iptables/kube-proxy stack with eBPF programs running directly in the Linux kernel. The result: lower CPU overhead for services with many endpoints, native network policy enforcement, and better observability via Hubble. This is Microsoft's recommended long-term networking configuration for AKS.

### Taint the system node pool to activate NAP

```powershell
.\04-setup-nap.ps1

# Watch NAP provision nodes in real time
kubectl get events -A --field-selector source=karpenter -w
kubectl get nodes,pods -n pets -o wide -w
```

---

## Step 2 — Deploy the AKS Store Demo App

The [AKS Store Demo](https://github.com/Azure-Samples/aks-store-demo) is a reference microservices application with nine components running in the `pets` namespace:

| Service | Technology | Role |
|---|---|---|
| `mongodb` | MongoDB 6 | Product catalogue persistence |
| `rabbitmq` | RabbitMQ 3 | Order queue broker |
| `order-service` | Node.js / Fastify | Accepts and queues orders |
| `makeline-service` | Go / Gin | Processes orders from queue |
| `product-service` | Rust / Actix | Product catalogue API |
| `store-front` | Vue.js / nginx | Customer-facing storefront |
| `store-admin` | Vue.js / nginx | Admin dashboard |
| `virtual-customer` | Node.js | Simulates customer orders |
| `virtual-worker` | Node.js | Processes orders (scaled by KEDA) |

Manifests are vendored locally in `manifests/aks-store/` for easy customization:

```powershell
.\03-deploy-app.ps1

# Verify all pods are Running
kubectl get pods -n pets
```

Expected output:
```
NAME                                READY   STATUS    RESTARTS   AGE
makeline-service-6b87c6f669-xr2pq   1/1     Running   0          2m
mongodb-0                           1/1     Running   0          2m
order-service-78465f5d44-fl782      1/1     Running   0          2m
product-service-5c94f8c7b-9q8lp     1/1     Running   0          2m
rabbitmq-0                          1/1     Running   0          2m
store-admin-6b87c4dc9d-9xklm        1/1     Running   0          2m
store-front-5c5f8c7db-5k2tr         1/1     Running   0          2m
virtual-customer-7d8f5b9c6-2nfzp    1/1     Running   0          2m
virtual-worker-9c6d4b87f-8m3xt      1/1     Running   0          2m
```

### Enable KEDA autoscaling for virtual-worker

```powershell
.\07-setup-keda-scaler.ps1

# Test KEDA scaling: flood the queue to trigger scale-out
kubectl scale deployment virtual-customer -n pets --replicas=4
kubectl get deploy -n pets -w
```

---

## Step 3 — Configure Azure SRE Agent

With the cluster and application running, the next step is to wire up the Azure SRE Agent. There are four configuration actions:

1. **Create the Azure SRE Agent resource**  
   In the Azure portal, search for *SRE Agent* → **+ Create**. Assign it to `Azure-SRE-Agent-Demo_RG`, name it `aks-sre-agent`, and enable **system-assigned managed identity**.

   > _Portal screenshot: Create Azure SRE Agent — Basics tab showing subscription, resource group, agent name, region, and managed identity toggle set to On._  
   > _(See Figure 1 in the [HTML version](./index.html))_

2. **Grant RBAC to the agent's managed identity**

   ```bash
   # Replace with your agent's managed identity object ID
   az role assignment create \
       --assignee "<agent-managed-identity-object-id>" \
       --role "Azure Kubernetes Service Cluster User Role" \
       --scope "/subscriptions/<sub-id>/resourcegroups/Azure-SRE-Agent-Demo_RG"

   az role assignment create \
       --assignee "<agent-managed-identity-object-id>" \
       --role "Monitoring Reader" \
       --scope "/subscriptions/<sub-id>/resourcegroups/Azure-SRE-Agent-Demo_RG"
   ```

3. **Add your resource group as a Managed Resource**  
   In the agent's *Managed Resources* blade, click **+ Add resource** and add `Azure-SRE-Agent-Demo_RG`. The agent now has visibility over every resource in the group — AKS cluster, Log Analytics workspace, and networking resources.

   > _Portal screenshot: Managed Resources blade showing `Azure-SRE-Agent-Demo_RG` with status **Connected**._  
   > _(See Figure 2 in the [HTML version](./index.html))_

4. **Add an Azure Monitor trigger**  
   Create the pod health alert rule, then configure it to route to the SRE Agent via an Action Group:

   ```bash
   az monitor metrics alert create \
       --name "pod-not-healthy" \
       --resource-group "Azure-SRE-Agent-Demo_RG" \
       --scopes "/subscriptions/<sub-id>/.../managedclusters/Azure-SRE-Agent-Demo-Cluster" \
       --condition "avg kube_pod_status_phase{phase=Failed} > 0" \
       --severity 1 \
       --action "sre-agent-action-group" \
       --evaluation-frequency "1m" \
       --window-size "5m"
   ```

   > _Portal screenshot: Triggers blade — Azure Monitor trigger configured with Sev0–Sev2 severity filter and action group webhook._  
   > _(See Figure 3 in the [HTML version](./index.html))_

### Incident Response Plan: three operating modes

| Mode | Behavior | Recommended Use |
|---|---|---|
| **Monitor Only** | Investigates and produces a root cause report. Makes **no changes**. | Initial rollout, compliance-sensitive environments |
| **Guided** | Proposes exact remediation commands. **Waits for human approval** before executing. | Building team confidence, moderate-severity alerts |
| **Autonomous** | Full loop: investigate → diagnose → remediate → verify → report. **No approval required.** | Production Sev0/Sev1 where MTTR is the priority |

> **⚡ Recommended ramp-up approach**  
> Start in **Guided** mode for 1–2 weeks. Review and approve the agent's proposed remediations to build operational confidence, then promote to **Autonomous** for Sev0/Sev1 alerts. The agent never performs destructive operations or escalates its own permissions.

> _Portal screenshot: Incident Response Plan blade — Autonomous mode selected, allowed actions checklist, notification integrations._  
> _(See Figure 4 in the [HTML version](./index.html))_

### Custom instructions for your environment

The Incident Response Plan supports free-text instructions that give the agent domain-specific context:

```
For AKS pod health alerts in the pets namespace:
1. Scan all namespaces for unhealthy pods first.
2. Prioritise OOMKilled and CrashLoopBackOff.
3. For OOMKilled: correlate NODE_OPTIONS / JVM flags against container memory limits
   before adjusting. Apply the minimum necessary increase.
4. After any patch, wait for rollout, then verify cluster-wide pod health.
5. Create a GitHub issue in the infra-ops repo with the incident summary.
```

---

## Step 4 — See It in Action: Autonomous OOMKilled Recovery

With everything wired up, let's trigger a real incident by setting the `order-service` memory limit below what its Node.js V8 heap requires.

### Trigger the incident

```powershell
# Set order-service memory limit to 16Mi — incompatible with 64MB V8 heap
kubectl patch deployment order-service -n pets --type='json' `
    -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"16Mi"}]'

# Watch pods enter CrashLoopBackOff
kubectl get pods -n pets -w
```

```
NAME                               READY   STATUS             RESTARTS   AGE
order-service-5f9d44b6c8-4bvsr     0/1     OOMKilled          1          12s
order-service-5f9d44b6c8-4bvsr     0/1     CrashLoopBackOff   2          28s
```

Within five minutes, Azure Monitor fires the Sev1 alert and the SRE Agent begins working immediately.

### The agent's autonomous response — T+0s to T+107s

| Time | Phase | Action |
|---|---|---|
| T+0s | **Plan** | Receives alert payload. Builds investigation plan: scan all namespaces, prioritise OOMKilled/CrashLoopBackOff, correlate root cause, apply minimal fix, verify. |
| T+5s | **Discover** | Connects to cluster via managed identity. Runs `kubectl get pods --all-namespaces`, filters for crash signals and restart counts > 0. |
| T+10s | **Identify** | Finds `order-service-5f9d44b6c8-4bvsr` and `order-service-5f9d44b6c8-fl782` in `pets` namespace — 14 restarts each, `Last State: OOMKilled`. |
| T+20s | **Root Cause** | Correlates 4 signals: Exit Code 137 + OOMKilled + 16Mi limit + `NODE_OPTIONS=--max-old-space-size=64`. V8 heap requires 64 MB — 4× the container budget. |
| T+30s | **Remediate** | Applies minimal JSON patch: memory limit 16Mi → 128Mi, request 8Mi → 64Mi. Triggers zero-downtime rolling update. |
| T+107s | **Verified** | Both pods Running 1/1, zero restarts. Cluster-wide sweep: zero unhealthy pods. Incident report published. |

### Root cause signals correlated by the agent

| Signal | Observed Value | What It Means |
|---|---|---|
| Container memory limit | `16Mi` | Maximum memory before Linux OOM killer terminates the process |
| `NODE_OPTIONS` | `--max-old-space-size=64` | V8 old-generation heap capped at 64 MB — 4× the limit |
| Exit code | `137` | SIGKILL sent by cgroup OOM killer (128 + 9) |
| Pod last state | `OOMKilled` | Kubernetes confirmed the termination reason |

### The exact patch applied

```bash
kubectl patch deployment order-service -n pets --type='json' -p='[
    {"op": "replace", "path": "/spec/template/spec/containers/0/resources/limits/memory",   "value": "128Mi"},
    {"op": "replace", "path": "/spec/template/spec/containers/0/resources/requests/memory", "value": "64Mi"}
  ]'
# deployment.apps/order-service patched

kubectl rollout status deployment/order-service -n pets
# deployment "order-service" successfully rolled out
```

### Before vs. After

| | Before (Crashing) | After (Recovered) |
|---|---|---|
| Pod status | CrashLoopBackOff | Running 1/1 |
| Restarts | 14 each | 0 |
| Memory limit | 16Mi | 128Mi |
| Memory request | 8Mi | 64Mi |
| V8 heap vs limit | 64 MB (4× over) | 64 MB (fits) |
| Cluster health | 2 unhealthy pods | 0 unhealthy pods |

### The agent's incident report

> _Portal screenshot: Incident History blade showing INC-2026-0407-001 — Status: Resolved, MTTR: 1m 47s, Root Cause: OOMKilled, Action: patch applied, Recommendation: update source manifest in Git._  
> _(See Figure 5 in the [HTML version](./index.html))_

**Incident INC-2026-0407-001 — Summary**

| Field | Value |
|---|---|
| Alert | [Sev1] pod-not-healthy |
| Resource | Azure-SRE-Agent-Demo-Cluster (Azure-SRE-Agent-Demo_RG) |
| Fired | 2026-04-07 21:07:13 UTC |
| Resolved | 2026-04-07 21:09:00 UTC |
| Root Cause | OOMKilled — container memory limit (16Mi) incompatible with Node.js V8 heap (64MB) |
| Action Taken | Patched order-service: memory limit 16Mi → 128Mi, request 8Mi → 64Mi |
| Post-State | 2/2 pods Running 1/1, 0 restarts. Cluster-wide: 0 unhealthy pods. |
| Recommendation | Update source manifest in Git — runtime patch will be overwritten on next CI/CD deploy. |

### Traditional response vs. Azure SRE Agent

| Traditional On-Call | Azure SRE Agent (Autonomous) |
|---|---|
| ❌ Alert pages engineer at 2 AM | ✅ Agent starts immediately |
| ❌ Opens laptop, connects VPN | ✅ Already authenticated via managed identity |
| ❌ Gets kubeconfig, scans namespaces | ✅ Scans all namespaces in parallel |
| ❌ Looks up exit code 137 | ✅ Correlates exit codes, specs, and env vars |
| ❌ Applies fix, monitors rollout | ✅ Applies minimal reversible patch, verifies rollout |
| ❌ Writes incident summary next morning | ✅ Structured report delivered instantly |
| ❌ **Typical MTTR: 30–60 minutes** | ✅ **MTTR: 1 minute 47 seconds** |

---

## Bonus: Node Auto-Provisioning in Action

While Azure SRE Agent handles incident response, NAP handles the infrastructure layer beneath. Scripts `05-arm-nodepool.ps1` and `06-arm-nodepool-v2.ps1` apply Karpenter `NodePool` manifests that bias node selection toward **ARM64 D-family** VMs on **Azure Linux (CBL-Mariner)** — offering up to 40% better price-performance for Node.js and Go workloads.

```powershell
.\05-arm-nodepool.ps1    # apply ARM64 NodePool preference
.\06-arm-nodepool-v2.ps1 # add Azure Linux AKSNodeClass

# Inspect NAP-provisioned nodes
kubectl get nodepool
kubectl describe nodepool default
```

---

## Next Steps & Resources

In this walkthrough, you:

1. Deployed a production-ready AKS cluster with NAP, Cilium, and KEDA
2. Deployed the AKS Store Demo application across nine microservices
3. Created an Azure SRE Agent with managed identity, managed resources, and an Azure Monitor trigger
4. Configured an autonomous Incident Response Plan with custom instructions
5. Watched the agent resolve a real OOMKilled incident in under two minutes with zero human intervention

The key insight isn't just the speed improvement — it's **consistency**. Azure SRE Agent runs the same structured methodology every time: plan, collect, analyze, act, verify, report. It doesn't skip the verification step at 3 AM, and it delivers the incident report before the on-call engineer has finished reading the alert.

### Extend the demo

- **Add more incident types**: configure alert rules for `CrashLoopBackOff`, `ImagePullBackOff`, and node resource pressure
- **Multi-cluster**: add a second AKS cluster to Managed Resources and watch the agent correlate cross-cluster signals
- **KEDA + SRE Agent**: let KEDA auto-scale on queue depth while SRE Agent handles pod health issues in parallel
- **Post-incident automation**: configure the agent to create GitHub issues or send Teams notifications after every resolution

### Resources

| Resource | Link |
|---|---|
| Demo repository | [github.com/hailugebru/azure-sre-agents-aks](https://github.com/hailugebru/azure-sre-agents-aks) |
| Azure SRE Agent documentation | [learn.microsoft.com/azure/sre-agent](https://learn.microsoft.com/azure/sre-agent/) |
| AKS Store Demo | [github.com/Azure-Samples/aks-store-demo](https://github.com/Azure-Samples/aks-store-demo) |
| Node Auto-Provisioning docs | [learn.microsoft.com/azure/aks/node-autoprovision](https://learn.microsoft.com/azure/aks/node-autoprovision) |
| KEDA on AKS | [learn.microsoft.com/azure/aks/keda-about](https://learn.microsoft.com/azure/aks/keda-about) |

---

*© 2026 Microsoft Corporation. All rights reserved.*

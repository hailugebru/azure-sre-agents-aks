# Autonomous AKS Incident Response with Azure SRE Agent

**Tags:** AKS, Azure SRE Agent, AI Ops, Node Auto-Provisioning, KEDA, Incident Response

> **Demo scope:** This walkthrough configures Azure SRE Agent with **Privileged** permissions and **Autonomous** run mode against a dedicated demo resource group. Validate these patterns against your organization's RBAC, networking, and change-control requirements before production adoption.

---

## In This Article

1. [Introduction — The Problem Azure SRE Agent Solves](#introduction)
2. [Solution Architecture](#solution-architecture)
3. [Prerequisites & Demo Repo](#prerequisites--demo-repo)
4. [Step 1 — Deploy an AKS Cluster with NAP](#step-1--deploy-an-aks-cluster-with-nap)
5. [Step 2 — Deploy the AKS Store Demo App](#step-2--deploy-the-aks-store-demo-app)
6. [Step 3 — Configure Azure SRE Agent](#step-3--configure-azure-sre-agent)
   - [Post-Incident GitHub Issue Automation](#post-incident-github-issue-automation)
7. [Step 4 — See It in Action: Two Real Incidents, Zero Escalations](#step-4--see-it-in-action-two-real-incidents-zero-escalations)
   - [Incident 1 — CPU Starvation, Alert-Driven (~8 min MTTR)](#incident-1-cpu-starvation-and-startup-probe-failures--alert-driven-mttr-8-minutes)
   - [Incident 2 — OOMKilled, Chat-Driven (~4 min MTTR)](#incident-2-oomkilled--chat-driven-mttr-4-minutes)
8. [Bonus: Node Auto-Provisioning in Action](#bonus-node-auto-provisioning-in-action)
9. [Next Steps & Resources](#next-steps--resources)
10. [Production Adoption Guidance](#production-adoption-guidance)

---

## Introduction

It's 2 AM. Azure Monitor fires a Sev1 alert: pods are crashing in your production AKS cluster. The traditional playbook kicks in — an on-call engineer is paged, logs in, runs a series of diagnostic commands, figures out the root cause, applies a fix, and verifies recovery. By the time that's done, **30 to 60 minutes have passed**.

For teams running containerized workloads on Azure Kubernetes Service (AKS), this manual response cycle is a source of alert fatigue, slow recovery times, and inconsistent remediation quality. **Azure SRE Agent** addresses this head-on: it is an AI-powered operations agent that connects to your Azure resources, receives alerts from Azure Monitor, and executes a structured investigate-diagnose-remediate-verify loop — fully autonomously.

In this post, I'll walk through that end-to-end flow in a tightly scoped demo environment configured for autonomous incident handling — covering cluster setup, application deployment, agent configuration, and two real incidents resolved without human intervention.

> **Scope note:** This demo uses Privileged permissions and Autonomous run mode against a single resource group. Azure SRE Agent also supports Reader permissions and Review run mode for teams that want investigation output without automated execution. Start there if autonomy is new to your environment.

| Metric | Result |
|---|---|
| Alert to Full Recovery (Incident 1) | **~8 minutes** |
| Human Interventions Required | **0** |
| Namespaces Scanned Automatically | **6 (40+ pods)** |
| Patches Applied Across Both Incidents | **5** |
| GitHub Issue Auto-Created | **Yes — [#1](https://github.com/hailugebru/azure-sre-agents-aks/issues/1)** |

> _Outcomes above reflect a single controlled lab run on April 10, 2026. MTTR will vary based on cluster size, telemetry latency, and failure type._

---

## Solution Architecture

The demo environment brings together three layers: an AKS cluster configured for modern scaling and networking patterns, the AKS Store reference application, and Azure SRE Agent integrated with Azure Monitor for incident-triggered investigation and remediation.

In Azure SRE Agent terminology, Azure Monitor acts as the **incident platform**, while access to Azure telemetry and AKS diagnostics comes from the agent's built-in Azure capabilities and RBAC permissions. External systems such as GitHub are added through **connectors**.

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
| Monitoring trigger | Azure Monitor metric alert | Detects pod phase failures; combine with container waiting signals for broader coverage |
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

> **Enterprise note:** If your environment uses outbound filtering or a browser proxy, allow access to `*.azuresre.ai` during agent setup. You also need sufficient Azure RBAC permissions to create role assignments for the agent's managed identity (Owner, User Access Administrator, or RBAC Administrator on the target scope).

---

## Step 1 — Deploy an AKS Cluster with NAP

The cluster uses **Node Auto-Provisioning (NAP)**, which automatically selects and manages VM capacity based on pending pod requirements. In AKS, NAP is built on Karpenter and uses `NodePool` and `AKSNodeClass` resources to express provisioning policy, architecture preference, and workload constraints — making it a good fit for demos that intentionally create burst, pressure, or mixed scheduling conditions. The cluster also uses Azure CNI Overlay with the Cilium eBPF dataplane.

> **Note:** NAP manages infrastructure capacity. Azure SRE Agent investigates and remediates incidents. They are orthogonal — the agent is not a cluster autoscaler and does not interact with NAP directly.

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
  --enable-azure-monitor-metrics \      # managed Prometheus
  --generate-ssh-keys
```

> **💡 Why Cilium?**  
> The `--network-dataplane cilium` flag replaces the legacy iptables/kube-proxy stack with eBPF programs running directly in the Linux kernel. The result: lower CPU overhead for services with many endpoints, native network policy enforcement, and better observability via Hubble. This is a well-supported modern AKS networking configuration — see the [AKS networking docs](https://learn.microsoft.com/azure/aks/azure-cni-overlay) for the latest guidance.

---

## Step 2 — Deploy the AKS Store Demo App

The [AKS Store Demo](https://github.com/Azure-Samples/aks-store-demo) is a reference microservices application with nine components running in the `pets` namespace — covering stateless services, stateful dependencies (MongoDB, RabbitMQ), and event-driven workers.

Manifests are vendored locally in `manifests/aks-store/` for easy customization:

```powershell
.\03-deploy-app.ps1

# Verify all pods are Running
kubectl get pods -n pets
```

### Enable KEDA autoscaling for virtual-worker

KEDA in AKS is a managed add-on that scales workloads from 0 to N based on external event sources. For `virtual-worker`, the trigger is the depth of the RabbitMQ `orders` queue.

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
   In the Azure portal, search for *SRE Agent* → **+ Create**. Scope it to `Azure-SRE-Agent-Demo_RG` and name it `aks-sre-agent`. Azure SRE Agent creates two managed identities during deployment: a **user-assigned managed identity (UAMI)** — which you work with for RBAC and connector scenarios — and a system-assigned identity used internally by the service.

   > _Portal screenshot: Create Azure SRE Agent — Basics tab showing subscription, resource group, agent name, region, and managed identity toggle set to On._  
   > _(See Figure 1 in the [HTML version](./index.html))_

2. **Grant RBAC to the agent's managed identity**

   Azure SRE Agent uses the UAMI for Azure resource access. During setup, Azure assigns core monitoring roles including Reader, Log Analytics Reader, Monitoring Reader, and Monitoring Contributor (note that Monitoring Contributor is assigned at subscription scope, not just resource group scope). The exact additional roles depend on your **permission level** (Reader vs Privileged) and the resource types in your managed resource groups.

   For this demo, I granted additional AKS-specific rights to allow cluster remediation. Treat these as scenario-specific additions, not a universal production baseline:

   ```bash
   # AKS Cluster Admin Role — full kubectl access via managed identity
   az role assignment create \
       --assignee "<uami-client-id>" \
       --role "Azure Kubernetes Service Cluster Admin Role" \
       --scope "/subscriptions/<sub-id>/resourcegroups/Azure-SRE-Agent-Demo_RG"

   # AKS Contributor — ARM-level read/write on the AKS resource
   az role assignment create \
       --assignee "<uami-client-id>" \
       --role "Azure Kubernetes Service Contributor Role" \
       --scope "/subscriptions/<sub-id>/resourcegroups/Azure-SRE-Agent-Demo_RG"
   ```

   > **Privileged vs. Standard**: Choose **Privileged** when adding the resource group in step 3 — required for the agent to apply patches autonomously. Standard gives read-only access suitable for Monitor Only mode.

3. **Add your resource group as a Managed Resource**  
   In the agent's *Managed Resources* blade, click **+ Add resource** and add `Azure-SRE-Agent-Demo_RG`. Managed resource groups define the Azure scope the agent can investigate. Within that scope, the quality of diagnosis and actions available still depend on the agent's RBAC permissions and the telemetry your environment emits.

   > _Portal screenshot: Managed Resources blade showing `Azure-SRE-Agent-Demo_RG` with status **Connected**._  
   > _(See Figure 2 in the [HTML version](./index.html))_

4. **Add an Azure Monitor trigger**

   **Part A — Connect Azure Monitor in the SRE Agent portal:**
   1. Go to **Builder → Incident platform**.
   2. Select **Azure Monitor** and turn **off** the *Quickstart response plan* toggle (you will create a custom one in the next step).
   3. Click **Save**. The portal generates a **webhook URL** — copy it.

   **Part B — Route the alert to the agent via Azure portal:**
   1. Open **Azure Portal → Monitor → Alerts → Action groups → + Create**.
   2. Under **Actions**, set Action type to **Webhook** and paste the webhook URL from Part A.
   3. Save the Action Group.
   4. Open the `pod-not-healthy` metric alert rule (scoped to the AKS cluster), attach the Action Group, and save.

   When the metric fires, the webhook delivers the alert payload to the agent, which matches it against your response plans and begins autonomous investigation within seconds.

   > **Alert coverage note:** `kube_pod_status_phase{phase="Failed"}` catches pods in the Failed phase, but `CrashLoopBackOff` is a container waiting reason — not a pod phase — and may not trigger this rule alone. For broader AKS production coverage, combine phase-based alerts with container waiting/termination signals and node-health rules.

   > _Portal screenshot: Builder → Incident platform blade showing Azure Monitor connected with the webhook URL and active response plan count._  
   > _(See Figure 3 in the [HTML version](./index.html))_

### Incident Response Plan: operating patterns

Azure SRE Agent uses two distinct control layers:
- **Permission level** (`Reader` or `Privileged`) — determines what Azure resources the agent can access and modify
- **Run mode** (`Review` or `Autonomous`) — determines whether the agent waits for approval before executing Azure infrastructure actions

In practice, most teams adopt the service in three patterns:

| Pattern | Permission | Run mode | Behavior | Recommended For |
|---|---|---|---|---|
| **Read-only investigation** | Reader | Review | Investigates and reports root cause. Makes **no changes**. | Initial rollout, compliance-sensitive environments |
| **Guided remediation** | Privileged | Review | Proposes exact actions. **Waits for human approval** before execution. | Building team confidence, moderate-severity alerts |
| **Autonomous remediation** | Privileged | Autonomous | Full loop: investigate → diagnose → remediate → verify → report. **No approval required.** | Production Sev0/Sev1 where MTTR is the priority |

> **⚡ Recommended ramp-up approach**  
> Start in the **Guided remediation** pattern for 1–2 weeks. Review and approve proposed actions to build operational confidence, then promote to **Autonomous** for Sev0/Sev1 alerts. Keep allowed actions narrowly scoped and validate behavior in Review mode before expanding autonomy.

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
5. After successful resolution, invoke the github-issue-tracker subagent to create
   a GitHub issue in hailugebru/azure-sre-agents-aks with the incident ID, root
   cause, patch applied, and a recommendation to update the source manifest in Git.
```

> These instructions shape the agent's workflow, but do not replace RBAC, telemetry quality, or the actual tool capabilities available to the agent.

---

### Post-Incident GitHub Issue Automation

With the agent resolving incidents autonomously, the final piece is closing the loop: every autonomous repair should produce a permanent, searchable audit trail in GitHub — eliminating manual post-mortem paperwork.

The **GitHub MCP connector** uses PAT-based Bearer token authentication (OAuth is not supported for MCP connectors). It gives the agent full GitHub API access — issue creation, code search, commit history, and PR analysis.

#### GitHub MCP Connector Setup

1. Go to **Builder > Connectors > + Add connector > MCP tab > GitHub MCP server**.
2. The portal pre-fills the URL as `https://api.githubcopilot.com/mcp/` and locks **Authentication method** to **Bearer token**.

   Generate a GitHub PAT at `github.com/settings/tokens` with:

   | PAT type | Required scope |
   |---|---|
   | **Classic PAT** | `repo` (includes issues read/write) |
   | **Fine-grained PAT** *(recommended)* | `Issues: Read and write` scoped to `hailugebru/azure-sre-agents-aks` |

   Paste the token into the **Personal access token (PAT) or API key** field and select **Next**.

4. After the connector shows **Connected**, select **Edit** → **MCP Tools** and enable:
   - `create_issue` *(required)*
   - `list_issues` *(recommended — lets the agent check for duplicates before filing)*
   - `get_issue` *(optional)*

5. Select **Save**.

> **Least-privilege note:** A fine-grained PAT scoped to a single repo with only `Issues: Read and write` is the recommended approach for production. It limits the agent's blast radius to issue management in one repository.

> _Portal screenshot: MCP connector list showing `github-mcp` with status **Connected** and tools `create_issue`, `list_issues` selected._  
> _(See Figure 6 in the [HTML version](./index.html))_

#### Create the `github-issue-tracker` subagent

A dedicated subagent keeps GitHub write access scoped and auditable. The main agent invokes it only after a successful resolution.

1. Go to **Builder > Subagent builder** and select **+ Create subagent**..

#### What the auto-created issue looks like

After Incident 1 resolved, the agent automatically filed [Issue #1](https://github.com/hailugebru/azure-sre-agents-aks/issues/1) at `16:01:26 UTC` — no human action. The issue contained:

- **Title:** `[AKS Alert] Pod Health Failures - pets namespace - 69e4dbba-6f33-5bc7-1700-c7d5e5b4000b`
- **Labels:** `aks`, `memory-management`, `pod-health`
- **Body:** Full incident summary with alert ID and timestamps, all unhealthy pods with failure states, root cause for each failure type, before/after tables for all 5 patches, post-patch `kubectl top` verification for all 9 pods, 7 actionable recommendations (including *"Update source manifests in Git"* and *"Add resource limit validation to the CI/CD pipeline to prevent sub-10m CPU limits from being deployed"*), and a deep link back to the SRE Agent investigation thread for a full audit trail.

---

## Step 4 — See It in Action: Two Real Incidents, Zero Escalations

These two incidents occurred on the same cluster in a single session on April 10, 2026, demonstrating both alert-driven and chat-driven investigation workflows — and two of the most common Kubernetes failure modes.

### Incident 1: CPU Starvation and Startup Probe Failures — Alert-Driven (MTTR: ~8 minutes)

**Trigger the incident.** Apply a misconfigured deployment with a 5 millicore CPU limit:

```powershell
kubectl patch deployment makeline-service -n pets --type='json' `
    -p='[
      {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/cpu","value":"5m"},
      {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"20Mi"}
    ]'

kubectl get pods -n pets -w
```

```
NAME                                  READY   STATUS             RESTARTS   AGE
makeline-service-59bcdc58fb-845wj     0/1     Error              1          32s
makeline-service-59bcdc58fb-845wj     0/1     CrashLoopBackOff   1          45s
```

Within five minutes, Azure Monitor fires the `pod-not-healthy` Sev1 alert (Alert ID `69e4dbba`, fired `15:36:15 UTC`) and the agent begins working immediately.

#### The agent's autonomous investigation

| Time | Phase | Action |
|---|---|---|
| T+0s | **Receive** | Alert payload arrives. Agent connects to cluster via managed identity. |
| T+30s | **Discover** | `kubectl get pods --all-namespaces` — scans 40+ pods across 6 namespaces |
| T+60s | **Identify** | `makeline-service`: 1 restart, last state `Error`, exit code `1` |
| T+90s | **Root Cause** | CPU limit `5m` + 6× startup probe `connection refused` events → service cannot bind port fast enough. Exit code `1` (not `137`) rules out OOMKill. |
| T+180s | **Expand** | `kubectl top pods`: `virtual-customer`, `virtual-worker`, and `mongodb` throttled at 112–200% of CPU limit |
| T+240s | **Remediate** | 4 patches applied sequentially, each rollout monitored before the next |
| T+480s | **Verified** | All 9 pods Running/Ready/0 restarts. Zero unhealthy pods cluster-wide. |

#### Signals correlated

| Signal | Value | Conclusion |
|---|---|---|
| CPU limit | `5m` (5 millicores) | Insufficient for Go/Gin service startup |
| Startup probe events | 6× `dial tcp: connection refused` | Service could not bind port under extreme CPU starvation |
| Exit code | `1` | Process error — not `137`, so not an OOMKill |
| Container logs (post-restart) | HTTP 200s, healthy | Crash was startup timing, not application bug |
| `kubectl top` output | 3 pods at 112–200% of limit | Cluster-wide CPU pressure contributing to the health alert |

#### Four patches applied sequentially

| Resource | Type | CPU limit before | CPU limit after | Mem limit before | Mem limit after |
|---|---|---|---|---|---|
| `makeline-service` | Deployment | `5m` | `50m` | `20Mi` | `64Mi` |
| `virtual-customer` | Deployment | `2m` | `10m` | — | — |
| `virtual-worker` | Deployment | `2m` | `10m` | — | — |
| `mongodb` | StatefulSet | `25m` | `50m` | — | — |

> _Portal screenshot: Incident History blade showing alert ID `69e4dbba`, Status: Resolved, 4 patches applied, cluster-wide sweep: 0 unhealthy pods._  
> _(See Figure 5 in the [HTML version](./index.html))_

---

### Incident 2: OOMKilled — Chat-Driven (MTTR: ~4 minutes)

Shortly after Incident 1, an engineer noticed `order-service` was unhealthy. **No alert needed** — the agent handles ad-hoc investigations from the chat window too.

**Trigger the incident.** Deploy `order-service-changed.yaml`, which has a 20Mi memory limit — far too low for Node.js/Fastify:

```powershell
kubectl apply -f .\manifests\aks-store\order-service-changed.yaml -n pets

kubectl get pods -n pets -w
```

```
NAME                               READY   STATUS             RESTARTS   AGE
order-service-75b944dd4b-m8td6     0/1     OOMKilled          1          18s
order-service-75b944dd4b-m8td6     0/1     CrashLoopBackOff   4          72s
```

**Chat prompt to the agent:**

```
The order-service pod in the pets namespace is not healthy.
Please investigate, identify the root cause, and fix it.
```

#### The agent's chat-driven response

| Time | Phase | Action |
|---|---|---|
| T+0s | **Receive** | Chat message received. Runs `kubectl describe pod order-service-75b944dd4b-m8td6 -n pets` |
| T+15s | **Identify** | Last state: `OOMKilled`, exit code `137`. Memory limit: `20Mi` |
| T+30s | **Correlate** | Checks ConfigMap: no `NODE_OPTIONS`, no heap flags. Zero log output (process killed before first write). Prior healthy pod baseline: 50Mi at runtime. |
| T+60s | **Remediate** | Patches memory limit `20Mi → 128Mi` (conservative headroom above the observed 50Mi runtime baseline), request `10Mi → 50Mi` |
| T+240s | **Verified** | New pod `order-service-7d9d56dfd6-nfhh2` Running, 74Mi/128Mi (58% utilization), 0 restarts |

#### Signals correlated

| Signal | Value | Conclusion |
|---|---|---|
| Exit code | `137` (SIGKILL) | OOM killer — not an application error |
| Container logs | **Empty — zero output** | Process killed by kernel before Node.js could start |
| `NODE_OPTIONS` in ConfigMap | Not present | Not a V8 heap mismatch — pure container limit issue |
| Memory limit | `20Mi` | 12.8× below the 50Mi the healthy pod used at runtime |

#### Patch applied

| Field | Before | After | Rationale |
|---|---|---|---|
| Memory limit | `20Mi` | `128Mi` | Conservative headroom above the observed 50Mi runtime baseline — stabilizes workload while preserving efficiency |
| Memory request | `10Mi` | `50Mi` | Aligned to observed runtime usage |

---

### Combined results

| | Incident 1 | Incident 2 |
|---|---|---|
| **Trigger** | Azure Monitor alert (automated) | Engineer chat (ad-hoc) |
| **Failure mode** | CPU starvation — startup probe timeouts | OOMKilled — memory limit too low for Node.js |
| **Key exit code** | `1` (process error) | `137` (SIGKILL from OOM killer) |
| **Patches applied** | 4 (3 Deployments + 1 StatefulSet) | 1 (Deployment) |
| **MTTR** | ~8 minutes | ~4 minutes |
| **Additional findings** | 3 other pods CPU-throttled at 112–200% | CPU at limit (101m/100m) — flagged for monitoring |
| **Post-state** | All 9 pods Running, 0 restarts | All 9 pods Running, 0 restarts |

> _Results reflect a single observed lab run. Actual MTTR depends on cluster size, telemetry configuration, and failure type._

### Automated GitHub issue — [#1](https://github.com/hailugebru/azure-sre-agents-aks/issues/1)

After verifying Incident 1, the agent automatically created [GitHub Issue #1](https://github.com/hailugebru/azure-sre-agents-aks/issues/1) at `16:01:26 UTC` with no human action. The issue includes before/after tables for all 5 patches, post-patch `kubectl top` output for all 9 pods, 7 actionable recommendations, and a deep link to the investigation thread — giving the team everything they need to update the source manifests permanently.

### Traditional response vs. Azure SRE Agent

| | Traditional On-Call | Azure SRE Agent |
|---|---|---|
| Alert → response begins | 5–15 min (page and wake up) | Instant (webhook) |
| Connect to cluster | 3–10 min (VPN, kubeconfig) | Near-immediate once permissions, incident routing, and AKS API access are already configured |
| Scan 40+ pods across 6 namespaces | 10–20 min (sequential `kubectl`) | ~1 min (automated, parallel) |
| Correlate CPU limits, events, logs | 10–15 min (domain knowledge required) | ~2 min (structured checklist, rules out wrong hypotheses) |
| Apply 4 patches + monitor each rollout | 10–20 min | ~3 min (auto-generated, sequential rollouts) |
| Cluster-wide verification sweep | 5–10 min | ~1 min |
| Incident report + GitHub issue | 15–30 min next morning | Automatic, complete in minutes |
| **Total MTTR** | **60–120 minutes** | **~8 minutes (7–15× faster)** |

---

## Bonus: Node Auto-Provisioning in Action

While Azure SRE Agent handles incident response, NAP manages infrastructure elasticity underneath. Scripts `05-arm-nodepool.ps1` and `06-arm-nodepool-v2.ps1` apply Karpenter `NodePool` manifests that bias node selection toward **ARM64 D-family** VMs on **Azure Linux** — Microsoft's AKS guidance describes Arm64 VMs as delivering up to 50% better price-performance than comparable x86 VMs for scale-out workloads. If targeting Azure Linux 3 (the current stable release), update the `AKSNodeClass` OS SKU accordingly.

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

1. Deployed a production-ready AKS cluster with NAP, Cilium, managed Prometheus, and KEDA
2. Deployed the AKS Store Demo application across nine microservices
3. Created an Azure SRE Agent with a User-Assigned Managed Identity, managed resources, and an Azure Monitor webhook trigger
4. Configured an autonomous Incident Response Plan with domain-specific custom instructions
5. Watched the agent detect and fix **two real incidents** — CPU starvation (alert-driven, ~8 min MTTR) and OOMKill (chat-driven, ~4 min MTTR) — applying 5 targeted patches with zero human intervention
6. Configured automatic GitHub issue creation to close the loop from runtime patch to tracked manifest recommendation

The key insight isn't just the speed improvement — it's **consistency**. Azure SRE Agent runs the same structured methodology every time: plan, collect, analyze, act, verify, report. It doesn't skip the verification step at 3 AM, and it delivers the incident report before the on-call engineer has finished reading the alert.

### Extend the demo

- **Add more incident types**: configure alert rules for `CrashLoopBackOff`, `ImagePullBackOff`, and node resource pressure
- **Multi-cluster**: add a second AKS cluster to Managed Resources and watch the agent correlate cross-cluster signals
- **KEDA + SRE Agent**: let KEDA auto-scale on queue depth while SRE Agent handles pod health issues in parallel
- **Post-incident automation**: Teams notifications — add the **Send notification (Teams)** connector under the `Notification` tab, create a `teams-notifier` subagent, and add an instruction to ping your on-call channel alongside the GitHub issue

### Resources

| Resource | Link |
|---|---|
| Demo repository | [github.com/hailugebru/azure-sre-agents-aks](https://github.com/hailugebru/azure-sre-agents-aks) |
| Azure SRE Agent documentation | [learn.microsoft.com/azure/sre-agent](https://learn.microsoft.com/azure/sre-agent/) |
| AKS Store Demo | [github.com/Azure-Samples/aks-store-demo](https://github.com/Azure-Samples/aks-store-demo) |
| Node Auto-Provisioning docs | [learn.microsoft.com/azure/aks/node-autoprovision](https://learn.microsoft.com/azure/aks/node-autoprovision) |
| KEDA on AKS | [learn.microsoft.com/azure/aks/keda-about](https://learn.microsoft.com/azure/aks/keda-about) |

---

## Production Adoption Guidance

Start with one scoped resource group, one incident type, and **Review mode** before expanding to Autonomous response. Validate four things first:

1. The agent can see the right telemetry (Log Analytics workspace connected, relevant metrics flowing)
2. The RBAC scope is intentionally narrow (use the minimum permission level for your use case)
3. The incident trigger matches the failure modes you actually care about (`kube_pod_status_phase{phase="Failed"}` alone misses most `CrashLoopBackOff` scenarios)
4. Post-incident artifacts — GitHub issues, Teams notifications — are actionable for your team

Azure SRE Agent adds the most value when observability, ownership, and operational boundaries are already reasonably mature.

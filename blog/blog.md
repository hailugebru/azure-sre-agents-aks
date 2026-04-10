# Autonomous AKS Incident Response with Azure SRE Agent

**Tags:** AKS, Azure SRE Agent, AI Ops, Incident Response, Node Auto-Provisioning, KEDA

> **Demo scope:** This walkthrough uses Azure SRE Agent with **Privileged** permissions and **Autonomous** run mode against a dedicated demo resource group. Azure SRE Agent separates **permission levels** (`Reader`, `Privileged`) from **run modes** (`Review`, `Autonomous`), so the safest production rollout is to start narrow and expand deliberately.

## Introduction

It’s 2 AM. A Sev1 alert fires on AKS. In many environments, that still means waking an engineer, correlating logs and metrics, running `kubectl`, applying a fix, and then documenting what happened. That process is slow, inconsistent, and expensive in human attention.

Azure SRE Agent is designed to reduce that toil. It can receive incidents, investigate Azure-native telemetry, reason over infrastructure state, propose or execute mitigations, verify the outcome, and capture the result as an operational artifact. In this demo, Azure Monitor acts as the **incident platform**, Azure diagnostics come from the agent’s built-in Azure capabilities, and GitHub is added as an external system through a connector.

This walkthrough shows that end-to-end flow on Azure Kubernetes Service (AKS): a lightweight environment setup, Azure SRE Agent configuration, and two real Kubernetes failure modes resolved without human intervention.

### Results from the demo run

| Metric | Result |
|---|---|
| Alert to full recovery (Incident 1) | **~8 minutes** |
| Human interventions required | **0** |
| Namespaces scanned automatically | **6 (40+ pods)** |
| Patches applied across both incidents | **5** |
| Post-incident GitHub issue | **Automatically created** |

> _These outcomes reflect a single controlled lab run on April 10, 2026. MTTR will vary based on telemetry latency, cluster size, and incident type._

---

## Azure SRE Agent on AKS in one minute

Azure SRE Agent has five concepts that matter most in an AKS incident workflow:

- **Incident platform** — where incidents originate. In this demo, that is Azure Monitor.
- **Built-in Azure capabilities** — the agent can use Azure Monitor, Log Analytics, Azure Resource Graph, Azure CLI/ARM, and AKS diagnostics without requiring external connectors.
- **Connectors** — these extend the agent to external systems such as GitHub, Teams, Kusto, and MCP servers.
- **Permission levels** — `Reader` for investigation and read-oriented access, `Privileged` for operational changes when allowed.
- **Run modes** — `Review` for approval-gated execution and `Autonomous` for direct execution.

That model matters more than any single prompt. If readers take one thing from this post, it should be this: **Azure SRE Agent is a governed incident-response system, not just a conversational assistant.**

---

## Demo environment

The demo combines three layers:

1. an AKS cluster configured for modern scaling and networking patterns,
2. the AKS Store sample application,
3. Azure SRE Agent integrated with Azure Monitor for incident-triggered investigation and remediation.

```text
Azure Monitor  →  Action Group  →  Azure SRE Agent  →  AKS Cluster
(Metric alert)    (Webhook)        (Investigate +       (NAP + Cilium
                                    Fix + Verify)         + KEDA)
```

The AKS cluster uses **Node Auto-Provisioning (NAP)**, which is built on Karpenter in AKS, along with Azure CNI Overlay, Cilium, and managed Prometheus metrics. NAP and Azure SRE Agent are complementary but separate: NAP manages infrastructure capacity, while the agent investigates and remediates incidents.

The application layer uses the **AKS Store Demo**, which gives a realistic mix of stateless services, stateful dependencies, and event-driven workers. KEDA scales `virtual-worker` on RabbitMQ queue depth, adding workload behavior the agent can observe during incident handling.

> **Important:** `kube_pod_status_phase{phase="Failed"}` is useful, but it does not cover every Kubernetes failure mode. `CrashLoopBackOff` is a **container waiting reason**, not a pod phase, so production-grade alerting should combine pod phase, waiting reason, termination reason, and node health signals.

---

## Minimal setup

If you want to reproduce the demo, the repo is here:

**Demo repository:** `https://github.com/hailugebru/azure-sre-agents-aks`

You need:
- an Azure subscription with AKS deployment permissions,
- Azure CLI with `aks-preview`,
- `kubectl` and PowerShell 7+,
- access to Azure SRE Agent.

```powershell
git clone https://github.com/hailugebru/azure-sre-agents-aks
cd azure-sre-agents-aks
notepad 00-variables.ps1
```

> **Enterprise note:** If your environment uses outbound filtering or proxy controls, allow `*.azuresre.ai`. You also need sufficient Azure RBAC rights to create role assignments for the agent’s managed identity.

### AKS cluster

```powershell
. .\00-variables.ps1
.\01-prerequisites.ps1
.\02-create-cluster.ps1
```

### Sample application and KEDA

```powershell
.\03-deploy-app.ps1
kubectl get pods -n pets

.\07-setup-keda-scaler.ps1
```

That is enough to create a realistic AKS environment for the incident flows below.

---

## Configure Azure SRE Agent

Azure SRE Agent setup in this demo comes down to four decisions: **identity**, **scope**, **incident routing**, and **execution control**.

### 1) Create the agent

Create an Azure SRE Agent resource in the portal and scope it to the demo resource group. During deployment, Azure SRE Agent creates two managed identities: a **user-assigned managed identity (UAMI)** that you use for RBAC and connector scenarios, and a system-assigned identity used internally by the service.

### 2) Grant the right access

Azure SRE Agent uses the UAMI for Azure resource access. Core monitoring roles are assigned during setup, and additional roles depend on your **permission level** and the resource types in your managed scope. In this demo, I added AKS-specific rights so the agent could perform cluster remediation. Treat those extra assignments as **scenario-specific**, not a universal production baseline.

```bash
az role assignment create \
  --assignee "<uami-client-id>" \
  --role "Azure Kubernetes Service Cluster Admin Role" \
  --scope "/subscriptions/<sub-id>/resourcegroups/Azure-SRE-Agent-Demo_RG"

az role assignment create \
  --assignee "<uami-client-id>" \
  --role "Azure Kubernetes Service Contributor Role" \
  --scope "/subscriptions/<sub-id>/resourcegroups/Azure-SRE-Agent-Demo_RG"
```

### 3) Add the resource group as a managed resource

Managed resource groups define the Azure scope the agent can investigate. Diagnosis quality and available actions still depend on RBAC and telemetry quality.

### 4) Connect Azure Monitor as the incident platform

Configure Azure Monitor in the Azure SRE Agent portal, copy the generated webhook URL, and route your AKS alert to it through an Azure Monitor Action Group. When the alert fires, Azure Monitor sends the incident payload to the agent, which evaluates it against the response plan and starts investigating. Azure Monitor is the **incident platform** in this design; it is not just another connector.

### Operating model: permissions and run modes

For production adoption, think in two layers:

- **Permission level** — what resources the agent can access and modify
- **Run mode** — whether the agent asks before acting

A pragmatic rollout looks like this:

- **Start:** `Reader` + `Review`
- **Then:** `Privileged` + `Review`
- **Finally:** `Privileged` + `Autonomous` for narrow, trusted incident paths

### Custom instructions

For this demo, I gave the agent explicit instructions for AKS pod health investigations:

```text
For AKS pod health alerts in the pets namespace:
1. Scan all namespaces for unhealthy pods first.
2. Prioritise OOMKilled and CrashLoopBackOff.
3. For OOMKilled: correlate NODE_OPTIONS / JVM flags against container memory limits before adjusting.
4. After any patch, wait for rollout, then verify cluster-wide pod health.
5. After successful resolution, create a GitHub issue with the incident ID, root cause, patch applied, and a recommendation to update the source manifest in Git.
```

These instructions shape the workflow, but they do not replace RBAC, telemetry quality, or actual tool availability.

### Post-incident GitHub issue

After remediation, I had the agent create a GitHub issue with the root cause, patches applied, and follow-up recommendations. Azure SRE Agent supports GitHub integration through its built-in connector, and MCP-based GitHub integration is useful when you want a more explicit MCP tool workflow. For this post, the important outcome is operational: the runtime fix becomes a tracked engineering artifact instead of tribal knowledge.

---

## Two real incidents

These incidents happened on the same cluster in one session and show the two most common ways teams use Azure SRE Agent on AKS:

1. **incident-triggered automation**
2. **ad hoc chat investigation**

### Incident 1 — CPU starvation (alert-driven, ~8 min MTTR)

I intentionally patched `makeline-service` to an unusably low CPU limit:

```powershell
kubectl patch deployment makeline-service -n pets --type='json' `
  -p='[
    {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/cpu","value":"5m"},
    {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"20Mi"}
  ]'
```

Azure Monitor fired the alert, and the agent:

- scanned the cluster,
- isolated the failing workload,
- ruled out OOM by checking exit code `1` instead of `137`,
- found broader CPU throttling with `kubectl top`,
- patched four workloads,
- verified the cluster returned to a healthy state.

**Outcome:** all nine pods returned healthy, with zero unhealthy pods left cluster-wide.

### Incident 2 — OOMKilled (chat-driven, ~4 min MTTR)

I then deployed a deliberately under-sized version of `order-service`:

```powershell
kubectl apply -f .\manifests\aks-store\order-service-changed.yaml -n pets
```

From chat, I asked the agent to investigate and fix the unhealthy pod. The agent:

- confirmed `OOMKilled` with exit code `137`,
- checked for `NODE_OPTIONS` and ruled out a heap-flag issue,
- compared the failed limit to prior healthy runtime behavior,
- increased the memory request and limit,
- verified the new pod was healthy.

**Outcome:** the service recovered without a human operator manually interacting with the cluster.

### Post-incident artifact

After Incident 1, the agent automatically created a GitHub issue with the incident context, remediation details, and follow-up recommendations. That closes the loop from live-site mitigation to engineering follow-up.

### Traditional on-call vs. Azure SRE Agent

| | Traditional on-call | Azure SRE Agent |
|---|---|---|
| Alert to response | 5–15 min | Instant |
| Connect to cluster | 3–10 min | Near-immediate once configured |
| Scan 40+ pods | 10–20 min | ~1 min |
| Correlate evidence | 10–15 min | ~2 min |
| Apply fixes and verify | 15–30 min | ~4 min |
| Post-incident reporting | Next morning | Immediate |
| **Total MTTR** | **60–120 min** | **~8 min** |

---

## Optional: Node Auto-Provisioning in Action

NAP handles infrastructure elasticity underneath the incident workflow. In this demo, I biased provisioning toward Arm64-capable Azure Linux nodes to explore cost-efficient scale-out behavior. Microsoft’s AKS guidance describes Arm64 VMs as delivering up to 50% better price-performance than comparable x86 VMs for scale-out workloads.

```powershell
.\05-arm-nodepool.ps1
.\06-arm-nodepool-v2.ps1
kubectl get nodepool
kubectl describe nodepool default
```

---

## Key takeaways

Azure SRE Agent resolved two real AKS incidents in this lab — one alert-driven, one chat-driven — and then created a post-incident GitHub issue to preserve the outcome.

The key value is not just speed. It is **consistency**:

- investigate,
- diagnose,
- remediate,
- verify,
- report.

### Three things to carry forward

1. **Azure SRE Agent is a governed incident-response system, not just a chatbot.** The most important controls are **permission levels** and **run modes**.
2. **Built-in Azure diagnostics cover most of the core workflow.** Use connectors when you want the agent to extend into systems such as GitHub or Teams.
3. **Start narrow.** One resource group, one incident type, `Review` first, then expand once telemetry, RBAC, and trigger coverage are validated.

### Next steps

- Add broader AKS alert coverage for restart loops, image pull failures, and node pressure
- Add Teams notifications for post-incident handoff
- Expand to multi-cluster managed scopes once the single-cluster path is trusted

### Resources

- Demo repo: `https://github.com/hailugebru/azure-sre-agents-aks`
- Azure SRE Agent docs: `https://learn.microsoft.com/azure/sre-agent/`
- AKS Store Demo: `https://github.com/Azure-Samples/aks-store-demo`
- Node Auto-Provisioning: `https://learn.microsoft.com/azure/aks/node-autoprovision`
- KEDA on AKS: `https://learn.microsoft.com/azure/aks/keda-about`

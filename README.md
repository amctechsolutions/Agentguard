# AgentGuard

**Native Salesforce 2GP Agentforce Testing & Red-Teaming Suite** (API v62.0)

AgentGuard enables Salesforce teams to define regression and adversarial Red-Team test suites (`Agent_Test_Suite__c`, `Agent_Test_Case__c`), execute asynchronous test runs against Agentforce agents (`AgentGuardRunnerQueueable`, `AgentGuardRuntimeClient`), evaluate deterministic + optional LLM-as-a-Judge assertions (`AgentGuardEvaluatorService`), and inspect results in the Lightning Experience `AgentGuard_Dashboard`.

---

## Prerequisites

- **Salesforce CLI** (`sf` v2.x — verified with `@salesforce/cli/2.153.5`)
- **Node.js** (verified with `node v24.21.0`) and npm dependencies installed (`npm install`)
- A **Dev Hub** org with **Second-Generation Packaging (2GP)** and **Scratch Orgs** enabled

---

## Local Verification (Jest)

Run the LWC unit test suite locally:

```bash
npm run test:unit
```

Expected: 3 test suites, 13 tests passing.

---

## Operator Deployment & 2GP Packaging Runbook

### 1. Authenticate Your Dev Hub

Log in to your Dev Hub org via web OAuth and set its alias to `DevHub`:

```bash
sf org login web -d -a DevHub
```

Verify the Dev Hub is authenticated:

```bash
sf org display -o DevHub
```

---

### 2. Spin Up a Scratch Org

Create a fresh Scratch Org using `config/project-scratch-def.json` (includes `LightningExperience`, `EinsteinGPT`, `Agentforce`, and `Bots` features):

```bash
sf org create scratch -f config/project-scratch-def.json -a AgentGuardScratch -d -y 7
```

---

### 3. Deploy Source & Run Apex Tests

Push/deploy the `force-app` metadata to the Scratch Org:

```bash
sf project deploy start -o AgentGuardScratch
```

Assign the `AgentGuard_Admin` permission set to your Scratch Org user:

```bash
sf org assign permset -n AgentGuard_Admin -o AgentGuardScratch
```

Run the full Apex test suite with code coverage:

```bash
sf apex run test -o AgentGuardScratch -l RunLocalTests -c -r human -w 10
```

*(Optional)* Open the Scratch Org to inspect the `AgentGuard` Lightning App and `AgentGuard_Dashboard` tab:

```bash
sf org open -o AgentGuardScratch
```

---

### 4. Create the 2GP Package

> **Note on Namespace:** `sfdx-project.json` currently has `"namespace": ""`.
> - For a **2GP Managed Package** (AppExchange), register a namespace in your Partner/Dev Hub org, link it to `DevHub`, and set `"namespace": "<your_namespace>"` in `sfdx-project.json` before running `sf package create`.
> - For an **Unlocked Package** (internal distribution without a namespace), use `--package-type Unlocked`.

Create the 2GP package in your Dev Hub (run once):

```bash
sf package create \
  --name AgentGuard \
  --description "AgentGuard - Native Agentforce Testing & Red-Teaming Suite" \
  --package-type Managed \
  --path force-app \
  --target-dev-hub DevHub
```

Create a validated package version (runs Apex tests and checks dependencies):

```bash
sf package version create \
  --package AgentGuard \
  --installation-key-bypass \
  --code-coverage \
  --wait 20 \
  --target-dev-hub DevHub
```

*(Optional)* Install the created package version into a clean Scratch Org to verify installation:

```bash
sf package install --package <04t...> -o AgentGuardScratch -w 10
```

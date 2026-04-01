# paper_context.md

## Paper Topic
Race Conditions and Safe Transition Protocol in SDV OTA Wave Switching

## Research Background
In SDV OTA backend environments, OTA campaigns are often rolled out in waves rather than updating the whole fleet at once. In Kubernetes + Istio environments, workload activation and AuthorizationPolicy propagation are asynchronous, so their order is not guaranteed. This can cause temporary security holes or service disruption during wave switching. :contentReference[oaicite:0]{index=0}

## Problem Statement
This study focuses on two layers.

### 1. External wave switching layer
During wave activation and deactivation, policy enforcement and pod state transitions are independent asynchronous operations. This may create temporary over-permission, unauthorized communication, or interruption of legitimate requests. :contentReference[oaicite:1]{index=1}

### 2. Internal OTA pipeline layer
The OTA backend is modeled as:
auth -> campaign -> package -> deploy

Even if external wave switching is protected, the system is still unsafe if internal stage-to-stage communication is too open. An attacker with limited initial access may laterally move to later stages. :contentReference[oaicite:2]{index=2}

## Threat Model
Assume the attacker:
- gains code execution in one pod or container
- has no Kubernetes API control privilege
- has no host-level privilege
- attempts internal lateral movement through overly permitted service paths
- may exploit timing gaps during activation and deactivation transitions :contentReference[oaicite:3]{index=3}

## Main Research Plan
### Week 1
Build Kubernetes + Istio environment and deploy four dummy services for the OTA pipeline. Verify service-to-service communication.

### Week 2
Define 3 activation orders, 3 deactivation orders, and 9 end-to-end combinations. Automate activation experiments and measure security hole duration and availability impact.

### Week 3
Finish deactivation and end-to-end experiments. Reproduce lateral movement inside the OTA pipeline without NetworkPolicy / AuthorizationPolicy.

### Week 4
Implement the main contribution: Hierarchical Safe Transition Protocol. Define OTAWave CRD, build a controller, and add condition gates for readiness, Envoy initialization, and AuthorizationPolicy synchronization. Enforce safe deactivation order: drain -> pod removal -> policy block.

### Week 5
Apply least-privilege NetworkPolicy and AuthorizationPolicy. Combine external transition control and internal microsegmentation. Validate end-to-end.

### Week 6
Define analysis metrics and compare:
1. no policy
2. external gate only
3. external + internal hierarchical protocol

### Week 7
Write the paper and finalize introduction, related work, threat model, scenario analysis, protocol design, experiments, and conclusion.

## Key Contribution
The paper argues that OTA wave switching security must be handled as a hierarchical problem:
- external transition safety alone is not enough
- internal stage-to-stage microsegmentation is also required
- readiness probe alone is insufficient
- safe transition requires readiness + Envoy initialization + policy synchronization checks
- combining external gating and internal microsegmentation is the most effective approach :contentReference[oaicite:4]{index=4}

## Evaluation Metrics
Track at least:
- security hole duration
- request success/failure rate
- policy propagation delay
- lateral movement blocking success rate
- Attack Window
- Transition Risk Window :contentReference[oaicite:5]{index=5}

## Related Work Keywords
Use these topics when summarizing references:
- Uptane
- Secure OTA updates
- Zero Trust Architecture
- MisMesh
- Service Mesh Security
- Kubernetes NetworkPolicy
- Istio AuthorizationPolicy
- Microsegmentation

## Usage
- `CLAUDE.md` explains what to do.
- `paper_context.md` explains why the project matters.
- Read this file whenever detailed research context is needed before coding, experimentation, or writing.
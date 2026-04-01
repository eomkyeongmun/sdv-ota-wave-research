# CLAUDE.md

## Project
Study race conditions in SDV OTA backend wave switching and implement a Hierarchical Safe Transition Protocol on Kubernetes + Istio.

## System
Use four dummy services:
auth -> campaign -> package -> deploy

## Threat Model
Assume an attacker has code execution in one pod, but no Kubernetes admin or host-level privilege.

## Goals
- reproduce unsafe wave transition scenarios
- measure security hole duration and availability impact
- reproduce lateral movement without internal policies
- implement safe transition protocol
- apply least-privilege microsegmentation
- compare results for the paper

## Weekly Plan
### Week 1
Build Kubernetes + Istio environment, deploy 4 dummy services, verify communication

### Week 2
Define 3 activation orders, 3 deactivation orders, and 9 end-to-end combinations. Automate activation experiments.

### Week 3
Finish deactivation and end-to-end experiments. Reproduce internal lateral movement without NetworkPolicy / AuthorizationPolicy.

### Week 4
Implement the Hierarchical Safe Transition Protocol with OTAWave CRD and controller. Add condition gates for readiness, Envoy initialization, and AuthorizationPolicy synchronization. Enforce safe deactivation order: drain -> pod removal -> policy block.

### Week 5
Apply least-privilege NetworkPolicy and AuthorizationPolicy. Combine external transition control with internal microsegmentation and validate end-to-end.

### Week 6
Define metrics and compare:
1. no policy
2. external gate only
3. external + internal hierarchical protocol

### Week 7
Write the paper: introduction, related work, threat model, scenario analysis, protocol design, experiments, conclusion.

## Metrics
Track:
- security hole duration
- request success/failure rate
- policy propagation delay
- lateral movement blocking success rate
- Attack Window
- Transition Risk Window

## Rules
- start with the smallest working MVP
- prefer reproducible scripts over manual steps
- keep every experiment measurable
- save logs, CSVs, plots, and tables for the paper

## First Task
Start with Week 1 only:
set up Kubernetes + Istio, deploy 4 dummy services, verify communication, and create a reference-summary template.
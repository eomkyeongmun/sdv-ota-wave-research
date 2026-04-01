# Reference Summary Template

> Copy this block for each paper you read.
> Fill in all fields. Leave none blank — write "N/A" if genuinely not applicable.

---

## [REF-XXX] Title of the Paper

| Field         | Value |
|---------------|-------|
| Authors       |       |
| Venue / Year  |       |
| DOI / URL     |       |
| Read on       |       |

### Problem
> What problem does this paper address? (2–3 sentences)

### Method / System
> What is the proposed approach, system, or technique?

### Key Results
> Main findings or measurements (use numbers where possible).

### Relevance to This Project
> How does this paper relate to OTA wave switching, Istio security, or the threat model?

Check all that apply:

- [ ] Uptane / OTA update protocol
- [ ] Kubernetes NetworkPolicy
- [ ] Istio AuthorizationPolicy
- [ ] Service mesh security / MisMesh
- [ ] Zero Trust Architecture
- [ ] Microsegmentation
- [ ] Race conditions / TOCTOU
- [ ] SDV / automotive security
- [ ] Other: ___________

### Quotes / Figures to Cite
> Copy the exact sentence you plan to cite (include page number if available).

### Limitations / Gaps
> What does this paper NOT cover that your research addresses?

### BibTeX
```bibtex
@article{key,
  author    = {},
  title     = {},
  journal   = {},
  year      = {},
  volume    = {},
  pages     = {},
  doi       = {},
}
```

---

## Completed Summaries

| ID       | Title (short)                         | Relevance Tags                              | Status   |
|----------|---------------------------------------|---------------------------------------------|----------|
| REF-001  | (example) Uptane: Securing OTA...     | Uptane, OTA, SDV                            | Done     |
| REF-002  | (example) MisMesh: ...                | Istio, Service mesh security                | Done     |

---

## Reading Queue

Papers to read next (add DOI/URL):

1. Uptane standard — https://uptane.github.io/
2. MisMesh (USENIX Security 2023)
3. Zero Trust Architecture (NIST SP 800-207)
4. Kubernetes NetworkPolicy deep dive
5. Istio AuthorizationPolicy propagation timing

---

## Topic Map

```
SDV OTA Security
├── External wave switching
│   ├── Uptane (supply-chain trust)
│   ├── Race condition / TOCTOU
│   └── Kubernetes rolling update semantics
└── Internal pipeline security
    ├── Zero Trust / Microsegmentation
    ├── Istio mTLS + AuthorizationPolicy
    ├── Service mesh attack surface (MisMesh)
    └── Lateral movement in microservices
```

---
layout: home

hero:
  name: "Occam Observer"
  text: "Out-of-Band Git Telemetry"
  tagline: Zero-latency semantic analysis and health telemetry for Git repositories. Designed for human reviewers and AI agents.
  actions:
    - theme: brand
      text: Get Started
      link: /guide/getting-started
    - theme: alt
      text: View API Reference
      link: /api/telemetry

features:
  - title: Zero-Latency Architecture
    details: Written in pure Bash and Go. Leverages high-speed Unix pipelines (grep, awk, mktemp) for instant sub-millisecond analysis without node_modules overhead.
  - title: Deep Intelligence
    details: Automatically extracts semantic mappings including infrastructure changes, schema mutations, network requests, and new function signatures.
  - title: O(1) Cache Reads
    details: Features an embedded CQRS pattern. The Go API Gateway serves the JSON cache with strict O(1) latency, perfect for high-throughput AI agents.
  - title: Beautiful Dashboard
    details: Ships with a modern React+Tailwind UI dashboard showing live telemetry vectors, git metadata, and an interactive API playground.
---

## Why Occam Observer?

Traditional CI/CD tools wait until code is pushed to analyze it. **Occam Observer** runs locally, instantly parsing `git diff` on every file save to evaluate code health, security violations, and tech debt *before* it's even committed. 

With the new v3.0 Intelligence Engine, it provides unparalleled semantic mappings so that AI co-pilots and security tools understand precisely *what* logic has changed in real-time.

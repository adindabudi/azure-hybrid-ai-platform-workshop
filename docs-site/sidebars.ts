import type { SidebarsConfig } from '@docusaurus/plugin-content-docs';

const sidebars: SidebarsConfig = {
  workshopSidebar: [
    'index',
    {
      type: 'category',
      label: 'M0 — Setup',
      collapsed: false,
      items: [
        'intro/setup',
        'intro/architecture-reality-check',
      ],
    },
    {
      type: 'category',
      label: 'M1 — Gateway Foundations',
      items: [
        'gateway-foundations/intro',
        'gateway-foundations/policy-anatomy',
        'gateway-foundations/policies',
        'gateway-foundations/enterprise-patterns',
      ],
    },
    {
      type: 'category',
      label: 'M2 — FinOps + Observability + Security',
      items: ['finops-observability-security/intro'],
    },
    {
      type: 'category',
      label: 'M3 — MCP Through the Gateway',
      items: ['mcp-secure-tool-access/intro'],
    },
    {
      type: 'category',
      label: 'M4 — Agent Framework',
      items: ['agent-framework/intro', 'agent-framework/migrate-from-langgraph'],
    },
    {
      type: 'category',
      label: 'M5 — Evaluation + Red Teaming',
      items: ['evaluation-redteam/intro'],
    },
    {
      type: 'category',
      label: 'M6 — OpenTelemetry End-to-End',
      items: ['otel-end-to-end/intro'],
    },
    'wrap-up/index',
    {
      type: 'category',
      label: 'Appendix — Industry playbooks (Indonesia)',
      collapsed: true,
      items: ['industry-playbooks/index'],
    },
    {
      type: 'category',
      label: 'Facilitator Guide',
      collapsed: true,
      items: [
        'facilitator-guide/index',
        'facilitator-guide/provision',
        'facilitator-guide/attendees',
        'facilitator-guide/apply-policies',
      ],
    },
  ],
};

export default sidebars;

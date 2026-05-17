import { themes as prismThemes } from 'prism-react-renderer';
import type { Config } from '@docusaurus/types';
import type * as Preset from '@docusaurus/preset-classic';

const config: Config = {
  title: 'Hybrid AI Platform Workshop',
  tagline: 'Build a production-grade AI gateway + agent platform across Azure and on-prem AKS',
  favicon: 'img/favicon.svg',

  // Update these to match your fork before the first GitHub Pages deploy.
  url: 'https://adindabudi.github.io',
  baseUrl: '/azure-hybrid-ai-platform-workshop/',

  organizationName: 'adindabudi',
  projectName: 'azure-hybrid-ai-platform-workshop',
  trailingSlash: false,

  onBrokenLinks: 'warn',
  onBrokenMarkdownLinks: 'warn',

  i18n: {
    defaultLocale: 'en',
    locales: ['en'],
  },

  markdown: {
    mermaid: true,
  },

  themes: ['@docusaurus/theme-mermaid'],

  presets: [
    [
      'classic',
      {
        docs: {
          routeBasePath: '/',
          sidebarPath: './sidebars.ts',
          editUrl:
            'https://github.com/adindabudi/azure-hybrid-ai-platform-workshop/edit/main/docs-site/',
        },
        blog: false,
        theme: {
          customCss: './src/css/custom.css',
        },
      } satisfies Preset.Options,
    ],
  ],

  themeConfig: {
    image: 'img/social-card.png',
    navbar: {
      title: 'Hybrid AI Platform Workshop',
      logo: {
        alt: 'Hybrid AI Platform Workshop',
        src: 'img/logo.svg',
      },
      items: [
        {
          type: 'docSidebar',
          sidebarId: 'workshopSidebar',
          position: 'left',
          label: 'Workshop',
        },
        {
          href: 'https://github.com/adindabudi/azure-hybrid-ai-platform-workshop',
          label: 'GitHub',
          position: 'right',
        },
      ],
    },
    footer: {
      style: 'dark',
      links: [
        {
          title: 'Workshop',
          items: [
            { label: 'M0 — Setup', to: '/intro/setup' },
            { label: 'M1 — Gateway Foundations', to: '/gateway-foundations/intro' },
            { label: 'M4 — Agent Framework', to: '/agent-framework/intro' },
          ],
        },
        {
          title: 'References',
          items: [
            { label: 'AI Landing Zone for APIM', href: 'https://aka.ms/ai-hub-gateway' },
            { label: 'AI Landing Zone for Foundry', href: 'https://github.com/Azure/AI-Landing-Zones' },
            { label: 'Microsoft Agent Framework', href: 'https://github.com/microsoft/agent-framework' },
          ],
        },
      ],
      copyright: `Workshop materials © ${new Date().getFullYear()} Hybrid AI Platform Workshop. Code is MIT-licensed.`,
    },
    prism: {
      theme: prismThemes.github,
      darkTheme: prismThemes.dracula,
      additionalLanguages: ['bash', 'python', 'hcl'],
    },
    admonitions: {
      keywords: ['note', 'tip', 'info', 'warning', 'danger', 'caution'],
    },
  } satisfies Preset.ThemeConfig,
};

export default config;

import { defineConfig } from 'vitepress'

// https://vitepress.dev/reference/site-config
export default defineConfig({
  title: 'Occam Observer',
  description: 'Out-of-band Git telemetry for human reviewers and AI agents',
  base: '/occam-observer/',
  lastUpdated: true,
  cleanUrls: true,
  appearance: 'dark',
  themeConfig: {
    logo: '/logo.svg',

    nav: [
      { text: 'Home',          link: '/' },
      { text: 'Guide',         link: '/guide/getting-started' },
      { text: 'API Reference', link: '/api/telemetry' },
    ],

    sidebar: [
      {
        text: 'Introduction',
        items: [
          { text: 'Getting Started', link: '/guide/getting-started' },
          { text: 'Architecture',    link: '/guide/architecture' },
        ],
      },
      {
        text: 'Engine Intelligence',
        items: [
          { text: 'State Vectors',      link: '/guide/state-vectors' },
          { text: 'Semantic Mappings',  link: '/guide/semantic-mappings' },
        ],
      },
      {
        text: 'Agent Integration',
        items: [
          { text: 'MCP server',             link: '/guide/mcp' },
          { text: 'Coordination API',       link: '/guide/coordination-api' },
          { text: 'REST API & JSON schema', link: '/api/telemetry' },
        ],
      },
    ],

    socialLinks: [
      { icon: 'github', link: 'https://github.com/fabriziosalmi/occam-observer' },
    ],

    footer: {
      message:   'Released under the MIT License.',
      copyright: 'Copyright © 2026 Fabrizio Salmi',
    },

    search: {
      provider: 'local',
    },
  },
})

import { defineConfig } from 'vitepress'

// https://vitepress.dev/reference/site-config
export default defineConfig({
  head: [
    // Everything this site loads is first-party. 'unsafe-inline' is required
    // because VitePress emits an inline appearance script and inline styles.
    // Applied to the built site only: `vitepress dev` serves HMR over a
    // websocket, which a strict connect-src would block as soon as the dev
    // server is not same-origin (--host, or a custom server.hmr.port).
    ...(process.env.NODE_ENV === 'production'
      ? [
          [
            'meta',
            {
              'http-equiv': 'Content-Security-Policy',
              content:
                "default-src 'self'; script-src 'self' 'unsafe-inline'; " +
                "style-src 'self' 'unsafe-inline'; img-src 'self' data:; " +
                "font-src 'self'; connect-src 'self'; base-uri 'self'; form-action 'self'",
            },
          ] as [string, Record<string, string>],
        ]
      : []),
  ],
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
      message:   
        'Released under the MIT License. · <a href="https://fabriziosalmi.github.io/privacy">Privacy &amp; legal</a>',
      copyright: 'Copyright © 2026 Fabrizio Salmi',
    },

    search: {
      provider: 'local',
    },
  },
})

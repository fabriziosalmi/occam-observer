import { defineConfig } from 'vitepress'

// https://vitepress.dev/reference/site-config
export default defineConfig({
  title: "Occam Observer",
  description: "Enterprise-Grade Out-of-Band Git Telemetry Engine",
  base: '/occam-observer/',
  lastUpdated: true,
  cleanUrls: true,
  appearance: 'dark', // Force dark mode for that professional hacker/admin look
  themeConfig: {
    // https://vitepress.dev/reference/default-theme-config
    logo: '/logo.svg',
    
    nav: [
      { text: 'Home', link: '/' },
      { text: 'Guide', link: '/guide/getting-started' },
      { text: 'API Reference', link: '/api/telemetry' }
    ],

    sidebar: [
      {
        text: 'Introduction',
        items: [
          { text: 'Getting Started', link: '/guide/getting-started' },
          { text: 'Architecture', link: '/guide/architecture' }
        ]
      },
      {
        text: 'Engine Intelligence',
        items: [
          { text: 'Telemetry Data', link: '/api/telemetry' },
          { text: 'State Vectors', link: '/guide/state-vectors' },
          { text: 'Semantic Mappings', link: '/guide/semantic-mappings' }
        ]
      }
    ],

    socialLinks: [
      { icon: 'github', link: 'https://github.com/fabriziosalmi/occam-observer' }
    ],
    
    footer: {
      message: 'Released under the MIT License.',
      copyright: 'Copyright © 2026 Fabrizio Salmi'
    },
    
    search: {
      provider: 'local'
    }
  }
})

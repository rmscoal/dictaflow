# DictaFlow Website

Promotional single-page website for DictaFlow. Built with Vite, React,
TypeScript, SCSS modules, and `classnames`.

Design follows the Voicet-style reference: Inter Tight for display type,
Inter for body text, purple `#6D5DF6` on a white-to-sky gradient, a floating
dictation window with side bubbles, and one conversion only: Download for
macOS. There is no pricing, login, or account flow.

## Develop

```sh
npm install
npm run dev
```

Open the local URL Vite prints (default http://127.0.0.1:5173/).

## Build

```sh
npm run build
npm run preview
```

The production build is static files in `dist/` and can be hosted on GitHub
Pages or any static host. Download buttons point to the latest GitHub
Release; update them in `src/lib/site.ts` if the release location changes.

## Structure

- `src/components/Nav.tsx` - pill navigation and Download action
- `src/components/Hero.tsx` - headline, CTAs, floating dictation window
- `src/components/Sections.tsx` - Features, How it works, Privacy, Models, FAQ, final CTA, footer
- `src/styles/_tokens.scss` - color, type, radius, and shadow tokens

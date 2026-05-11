# Workshop docs site (Docusaurus)

Hosted on GitHub Pages from `main`. CI lives in
[`.github/workflows/deploy-docs.yml`](../.github/workflows/deploy-docs.yml).

## Local preview

```bash
cd docs-site
npm install
npm run start
# open http://localhost:3000/hybrid-ai-platform-workshop/
```

## Build for production

```bash
npm run build
npm run serve     # serves the built site locally
```

## First-time GitHub Pages setup

1. Push the repo to GitHub (private OK for now; flip public later if you
   want the site to be world-accessible).
2. Go to **Settings → Pages → Build and deployment → Source** and select
   **GitHub Actions** (not "Deploy from a branch").
3. Update `url`, `baseUrl`, `organizationName`, and `projectName` in
   [`docusaurus.config.ts`](./docusaurus.config.ts) to match the GitHub
   org / repo you forked into.
4. Push to `main` — the workflow runs on changes under
   [`docs-site/**`](./) and publishes to
   `https://<your-github-username>.github.io/<your-repo>/`.

## Why GitHub Pages and not Container Apps

- Static docs do not need a 24/7 container.
- Container Apps **is not available in every region** (Indonesia
  Central, for example) — hosting docs in a different region from the
  one the workshop teaches about would be ironic for a workshop on
  in-region data residency.
- Anyone who forks this repo gets a working docs site in their own
  GitHub org with zero infra changes.
- If you are fully air-gapped, `npm run build` produces a `build/`
  folder that can be served from any static host.

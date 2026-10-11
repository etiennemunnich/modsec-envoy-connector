# Publishing these pages

Includes getting started, early-testing/UAT, install/build, how-it-works / fail-closed / config / troubleshooting (thin Pages entries), testing suite, the ASH scan page, architecture, and the body-mode pages.

## Already works without Pages

Open any markdown file under `docs/modes/` on github.com. GitHub Flavored Markdown renders the Mermaid diagrams.

## GitHub Pages (Docsify)

1. **Settings → Pages → Build and deployment**
2. Source: **Deploy from a branch**
3. Branch: `main`, folder: **`/docs`**
4. After deploy, open `/modes/` on the Pages URL (this folder’s `index.html`).

`docs/modes/.nojekyll` keeps GitHub from running Jekyll on this Docsify shell. Mermaid is loaded from jsDelivr in `index.html`.

## GitHub Wiki (optional mirror)

```bash
git clone https://github.com/etiennemunnich/modsec-envoy-connector.wiki.git
# copy *.md from docs/modes/ (rename README.md → Home.md if you want a wiki Home)
git -C modsec-envoy-connector.wiki add -A && git -C modsec-envoy-connector.wiki commit -m "Sync docs/modes Pages" && git -C modsec-envoy-connector.wiki push
```

Enable the wiki under **Settings → Wikis** if it is off. In-repo `docs/modes/` remains the reviewable source of truth for PRs.

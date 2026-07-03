# Custom domain setup

Your domain is recorded in `.site-config` as `DOMAIN_NAME`, but pointing it at
your host is a DNS change this integration can't make for you — it happens at
your domain registrar or DNS provider, not in this repo.

Typical records, once you know where the site is hosted:

- **Apex domain** (`example.com`): an `A`/`AAAA` record (or `ALIAS`/`ANAME` if
  your DNS provider supports it) pointing at your host's IP addresses.
- **Subdomain** (`www.example.com`, or any other subdomain): a `CNAME` record
  pointing at the hostname your host gives you (e.g.
  `your-project.pages.dev` for Cloudflare Pages).
- Most hosts also want a domain-verification `TXT` record before they'll
  issue a TLS certificate for the domain — check your host's dashboard for
  the exact value.

DNS changes can take anywhere from a few minutes to 48 hours to propagate,
depending on your records' TTL and your registrar.

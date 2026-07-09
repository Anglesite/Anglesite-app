# Inbox

The Inbox integration adds a **Keystatic-managed collection** for messages you want to keep track
of on your own site instead of (or alongside) email.

## Adding a message

1. Open your site in Anglesite and start the dev server (or run `npx astro dev` inside `Source/`).
2. Visit `/keystatic` in the preview.
3. Under **Inbox**, click **Create**, and fill in the subject, sender, received date, and message.
4. Save — the entry is written to `src/content/inbox/` as a Markdown file in your site's git repo.

Use it for anything you'd otherwise handle by copying an email into a note: a message forwarded
from your contact form provider, a question someone asked in person, a reminder to follow up.

## What this doesn't do yet

There's no visitor-facing form that writes directly into this Inbox — visitor messages today go
through the [Contact Form integration](../pages/contact.astro) (Formspree or a mailto: link).
Wiring a live submission pipeline into this Inbox is tracked in
[#587](https://github.com/Anglesite/Anglesite-app/issues/587).

import type { APIRoute } from "astro";
import { readConfig } from "../../scripts/config";

export const GET: APIRoute = () => {
  const name = readConfig("PWA_SITE_NAME") ?? "This site";
  const manifest = {
    name,
    short_name: name.length > 12 ? `${name.slice(0, 11)}…` : name,
    description: readConfig("PWA_DESCRIPTION") ?? "",
    start_url: "/",
    id: "/",
    display: "standalone",
    orientation: "any",
    scope: "/",
    background_color: "#ffffff",
    theme_color: readConfig("PWA_THEME_COLOR") ?? "#000000",
    icons: [
      { src: "/icons/icon-192.png", sizes: "192x192", type: "image/png" },
      { src: "/icons/icon-512.png", sizes: "512x512", type: "image/png" },
      { src: "/icons/icon-maskable-192.png", sizes: "192x192", type: "image/png", purpose: "maskable" },
      { src: "/icons/icon-maskable-512.png", sizes: "512x512", type: "image/png", purpose: "maskable" },
    ],
  };

  return new Response(JSON.stringify(manifest), {
    headers: { "Content-Type": "application/manifest+json" },
  });
};

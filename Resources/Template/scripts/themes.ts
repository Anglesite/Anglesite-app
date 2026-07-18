// Theme DATA lives in themes.json — the single shared source of truth. The app's
// AnglesiteCore/ThemeCatalog decodes the same file, so edits there flow to both sides.
// This module just re-exposes it with the historical typed `THEMES` record shape.
import themesData from "./themes.json";

export interface Theme {
  displayName: string;
  description: string;
  bestFor: string[];
  vars: Record<string, string>;
}

export const THEMES: Record<string, Theme> = Object.fromEntries(
  themesData.map(({ id, ...theme }) => [id, theme]),
);

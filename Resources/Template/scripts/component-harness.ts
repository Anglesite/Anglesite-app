import { createComponent, renderComponent, renderTemplate } from "astro/runtime/server/index.js";
import type { ComponentSlots } from "astro/runtime/server/index.js";

export type ComponentModuleMap = Record<string, () => Promise<unknown>>;

export interface SlotSample {
  name: string;
  label: string;
}

interface HarnessComponentProps {
  Component: unknown;
  props: Record<string, unknown>;
  slotSamples: SlotSample[];
}

const renderHarnessComponent = (
  $$result: any,
  { Component, props, slotSamples }: HarnessComponentProps,
) => {
  const slots: ComponentSlots = {
    default: () => renderTemplate`<span class="anglesite-harness-slot-sample">Slot content</span>`,
  };

  for (const sample of slotSamples) {
    slots[sample.name] = () =>
      renderTemplate`<span class="anglesite-harness-slot-sample">${sample.label}</span>`;
  }

  return renderComponent($$result, "HarnessComponent", Component, props, slots);
};

export const HarnessComponent = createComponent(renderHarnessComponent as any);

export function resolveComponentKey(name: string, modules: ComponentModuleMap): string | undefined {
  return [`/src/components/${name}.astro`, `/src/layouts/${name}.astro`].find((key) => key in modules);
}

export function parseProps(raw: string | null): Record<string, unknown> {
  if (!raw) return {};

  try {
    const value: unknown = JSON.parse(raw);
    return isPlainRecord(value) ? value : {};
  } catch {
    return {};
  }
}

export function namedSlotSamples(source: string): SlotSample[] {
  const names = new Set<string>();
  const slotPattern = /<slot\b[^>]*\bname\s*=\s*(?:"([^"]+)"|'([^']+)'|{["']([^"']+)["']})[^>]*>/g;

  for (const match of source.matchAll(slotPattern)) {
    const name = match[1] ?? match[2] ?? match[3];
    if (name) names.add(name);
  }

  return Array.from(names, (name) => ({
    name,
    label: `${labelForSlot(name)} slot content`,
  }));
}

function isPlainRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function labelForSlot(name: string): string {
  return name
    .replace(/[-_]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .replace(/\b\w/g, (char) => char.toUpperCase());
}

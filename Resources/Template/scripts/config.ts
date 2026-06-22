import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

export function readConfigFromString(content: string, key: string): string | undefined {
  const safeKey = key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return content.match(new RegExp(`^${safeKey}=(.+)$`, "m"))?.[1]?.trim();
}

const _defaultConfigPath = resolve(process.cwd(), ".site-config");
let _cache: Record<string, string> | null = null;

function loadDefaultConfig(): Record<string, string> {
  if (_cache !== null) return _cache;
  const result: Record<string, string> = {};
  if (existsSync(_defaultConfigPath)) {
    const content = readFileSync(_defaultConfigPath, "utf-8");
    for (const line of content.split("\n")) {
      const eq = line.indexOf("=");
      if (eq > 0) {
        const k = line.slice(0, eq).trim();
        const v = line.slice(eq + 1).trim();
        if (k) result[k] = v;
      }
    }
  }
  _cache = result;
  return _cache;
}

export function readConfig(
  key: string,
  configPath?: string,
): string | undefined {
  if (configPath !== undefined && configPath !== _defaultConfigPath) {
    if (!existsSync(configPath)) return undefined;
    return readConfigFromString(readFileSync(configPath, "utf-8"), key);
  }
  return loadDefaultConfig()[key];
}

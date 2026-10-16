export interface PlatformConfig {
  enabled: boolean;
  notice: string;
  endpoint?: string;
  tokenFormula?: string;
}


export interface ExtensionManifest {
  parserVersion: string;
  minAppVersion: string;
  sha256: string;
  signature: string;
  platforms?: Record<string, PlatformConfig>;
  headers?: Record<string, Record<string, string>>;
}

export const PARSER_PUBLIC_KEY_HEX =
  "ca4f1c302d00220e32178d2e9b47fd589dffc38e8c9711fe93327a44aa199ded";

export const MANIFEST_URL =
  "https://raw.githubusercontent.com/joopererer/EasySave/master/spec/manifest.json";

export function hexToBytes(hex: string): Uint8Array {
  const clean = hex.trim();
  const bytes = new Uint8Array(clean.length / 2);
  for (let i = 0; i < clean.length; i += 2) {
    bytes[i / 2] = parseInt(clean.substring(i, i + 2), 16);
  }
  return bytes;
}

export function canonicalizeManifest(val: unknown): string {
  function sortObj(v: unknown): unknown {
    if (v === null || typeof v !== "object" || Array.isArray(v)) return v;
    const sorted: Record<string, unknown> = {};
    for (const key of Object.keys(v as Record<string, unknown>).sort()) {
      if (key === "signature") continue;
      sorted[key] = sortObj((v as Record<string, unknown>)[key]);
    }
    return sorted;
  }
  return JSON.stringify(sortObj(val));
}

export async function verifyManifestSignature(
  manifest: ExtensionManifest,
  publicKeyHex = PARSER_PUBLIC_KEY_HEX,
): Promise<boolean> {
  try {
    if (!manifest.signature || manifest.signature.length !== 128) return false;
    const pubBytes = hexToBytes(publicKeyHex);
    const sigBytes = hexToBytes(manifest.signature);
    const canonicalString = canonicalizeManifest(manifest);
    const dataBytes = new TextEncoder().encode(canonicalString);

    const key = await crypto.subtle.importKey(
      "raw",
      pubBytes as unknown as BufferSource,
      { name: "Ed25519" },
      false,
      ["verify"],
    );
    return await crypto.subtle.verify(
      { name: "Ed25519" },
      key,
      sigBytes as unknown as BufferSource,
      dataBytes as unknown as BufferSource,
    );
  } catch {
    return false;
  }
}

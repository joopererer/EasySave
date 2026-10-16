import { describe, it, expect } from "vitest";
import crypto from "crypto";
import {
  canonicalizeManifest,
  hexToBytes,
  verifyManifestSignature,
  PARSER_PUBLIC_KEY_HEX,
} from "../src/manifest";

describe("Extension manifest signature verification", () => {
  it("verifies canonical manifest signature and rejects tampered fields", async () => {
    // Generate a fresh Ed25519 test keypair
    const { publicKey, privateKey } = crypto.generateKeyPairSync("ed25519");

    // Export raw 32-byte public key hex
    const pubKeyDer = publicKey.export({ type: "spki", format: "der" });
    // SPKI header for Ed25519 is 12 bytes: 302a300506032b6570032100 followed by 32 bytes raw key
    const rawPubKey = pubKeyDer.subarray(pubKeyDer.length - 32);
    const testPubHex = rawPubKey.toString("hex");

    expect(testPubHex).not.toBe(PARSER_PUBLIC_KEY_HEX);

    const baseManifest = {
      parserVersion: "1.5.0",
      minAppVersion: "1.0.0",
      sha256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      signature: "",
      platforms: {
        xhs: {
          enabled: false,
          notice: "小红书维护中",
        },
        instagram: {
          enabled: true,
          notice: "",
        },
      },
      headers: {
        xhs: { "User-Agent": "EasySave" },
      },
    };

    const canonicalStr = canonicalizeManifest(baseManifest);
    const sig = crypto.sign(null, Buffer.from(canonicalStr, "utf8"), privateKey);
    const validSigHex = sig.toString("hex");

    const signedManifest = {
      ...baseManifest,
      signature: validSigHex,
    };

    // 1. Valid signature passes
    const isValid = await verifyManifestSignature(signedManifest, testPubHex);
    expect(isValid).toBe(true);

    // 2. Tampered platform switch (enabled: false -> true) fails
    const tamperedPlatform = {
      ...signedManifest,
      platforms: {
        ...signedManifest.platforms,
        xhs: {
          enabled: true,
          notice: "小红书维护中",
        },
      },
    };
    expect(await verifyManifestSignature(tamperedPlatform, testPubHex)).toBe(false);

    // 3. Tampered notice fails
    const tamperedNotice = {
      ...signedManifest,
      platforms: {
        ...signedManifest.platforms,
        xhs: {
          enabled: false,
          notice: "被篡改的提示",
        },
      },
    };
    expect(await verifyManifestSignature(tamperedNotice, testPubHex)).toBe(false);

    // 4. Tampered version fails
    const tamperedVersion = {
      ...signedManifest,
      parserVersion: "2.0.0",
    };
    expect(await verifyManifestSignature(tamperedVersion, testPubHex)).toBe(false);

    // 5. Tampered SHA256 fails
    const tamperedSha = {
      ...signedManifest,
      sha256: "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    };
    expect(await verifyManifestSignature(tamperedSha, testPubHex)).toBe(false);

    // 6. Bad signature hex fails
    const badSigManifest = {
      ...signedManifest,
      signature: "00".repeat(64),
    };
    expect(await verifyManifestSignature(badSigManifest, testPubHex)).toBe(false);
  });
});

import { describe, it, expect, beforeAll } from 'vitest';
import { readFileSync } from 'fs';
import { join, dirname, resolve } from 'path';
import { fileURLToPath } from 'url';

// Helper to get __dirname in ES modules
const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const fixturesDir = resolve(__dirname, '../../spec/fixtures');
const sourcesPath = resolve(fixturesDir, 'sources.json');
const parserBundlePath = resolve(__dirname, '../../app/assets/parser/parser.js');

describe('Parser bundle verification', () => {
  let EasySaveParser: any;

  beforeAll(() => {
    // Load the bundled parser IIFE and execute it to expose EasySaveParser on global
    const bundleCode = readFileSync(parserBundlePath, 'utf-8');
    // Create a context with browser-like globals
    const vm = require('vm');
    const context = vm.createContext({}) as any;
    // Provide URL constructor (needed for hostnameOf function)
    context.URL = require('url').URL;
    // The bundle expects a 'self' or 'window' global; we'll provide an empty object
    const mockWindow = {};
    context.window = mockWindow;
    context.self = mockWindow;
    context.global = context;
    // Execute the bundle
    vm.runInContext(bundleCode, context, { filename: 'parser.js' });
    // Retrieve the exported parser
    // @ts-ignore
    EasySaveParser = mockWindow.EasySaveParser || context['global']['EasySaveParser'];
    if (!EasySaveParser) {
      throw new Error('Failed to load EasySaveParser from bundle');
    }
  });

  // Helper to read directory synchronously
  function readdirSyncSync(dir: string): string[] {
    try {
      return require('fs').readdirSync(dir);
    } catch (e) {
      return [];
    }
  }

  // Helper to load sources.json
  function loadSources(): Record<string, Record<string, string>> {
    const sourcesJson = readFileSync(sourcesPath, 'utf-8');
    return JSON.parse(sourcesJson);
  }

  // Helper to load fixture pairs for a platform
  function getFixturePairs(platform: string) {
    const platformDir = join(fixturesDir, platform);
    const platforms = readdirSyncSync(fixturesDir);
    if (!platforms.includes(platform)) {
      return [];
    }
    const files = readdirSyncSync(platformDir);
    const sources = loadSources();
    const platformSources = sources[platform] || {};
    const pairs = [];
    for (const file of files) {
      if (file.endsWith('.expected.json')) continue;
      const isHtml = file.endsWith('.html');
      const isJson = platform === 'x' && file.endsWith('.json');
      if (isHtml || isJson) {
        const ext = isHtml ? '.html' : '.json';
        const inputPath = join(platformDir, file);
        const jsonPath = join(platformDir, file.replace(ext, '.expected.json'));
        const input = readFileSync(inputPath, 'utf-8');
        const expected = JSON.parse(readFileSync(jsonPath, 'utf-8'));
        // Get pageUrl from sources.json
        const basename = file.replace(ext, '');
        const url = platformSources[basename] || `https://${platform}.com/test/${basename}`;
        pairs.push({ input, expected, url });
      }
    }
    return pairs;
  }

  // Test parse function for each platform
  for (const platform of ['xhs', 'instagram', 'x']) {
    const pairs = getFixturePairs(platform);
    describe(`parse() for ${platform}`, () => {
      for (const { input, expected, url } of pairs) {
        it(`should parse ${url}`, () => {
          const resultJson = EasySaveParser.parse(input, url);
          const result = JSON.parse(resultJson);
          // Check if this is a failure case fixture (has top-level error field)
          const isFailureFixture = !!(expected as any).error;

          if (isFailureFixture) {
            // Failure case fixture: expect parser to return failure
            expect(result.ok).toBe(false);
            // Compare only the error code (not message)
            expect(result.error.code).toEqual((expected as any).error.code);
          } else {
            // Success case fixture: expect parser to return success
            expect(result.ok).toBe(true);
            // Compare the data objects
            expect(result.data).toEqual(expected);
          }
        });
      }
    });
  }

  // Test parsePage function exists
  it('parsePage function exists', () => {
    expect(typeof EasySaveParser.parsePage).toBe('function');
  });

  // Test calculateToken function exists
  it('calculateToken function exists', () => {
    expect(typeof EasySaveParser.calculateToken).toBe('function');
    expect(EasySaveParser.calculateToken('2110916144072913327')).toBe('547mzovpdmp');
  });
});
import { defineConfig } from 'vitest/config';
import { cloudflareTest } from '@cloudflare/vitest-plugin';
export default defineConfig({ plugins: [cloudflareTest({ wrangler: { configPath: './wrangler.jsonc' }, miniflare: { bindings: { BOOTSTRAP_TOKEN: 'test-bootstrap-only-not-a-deployment-secret' } } })] });

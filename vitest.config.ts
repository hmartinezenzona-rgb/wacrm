import { defineConfig } from 'vitest/config';

export default defineConfig({
  resolve: {
    tsconfigPaths: true,
  },
  test: {
    environment: 'node',
    // `pruebas/` holds tests for code that does not live in src/: the n8n Cerebro
    // nodes, which are deployed as workflow `jsCode` and were untestable until now.
    include: ['src/**/*.test.ts', 'src/**/*.test.tsx', 'pruebas/**/*.test.ts'],
    // Dummy secrets — encryption.ts / webhook-signature.ts read these
    // at module load. Tests never hit a real Meta/Supabase service, so
    // any 32-byte hex / non-empty string will do; keep them lexically
    // identical to the CI build env so behaviour matches.
    env: {
      ENCRYPTION_KEY:
        '0000000000000000000000000000000000000000000000000000000000000000',
      META_APP_SECRET: 'test-meta-app-secret',
    },
    clearMocks: true,
    // The suite is large and jsdom-heavy; on a loaded machine the default 5 s
    // is not enough for the async-render files and they failed only when the
    // whole suite ran in parallel (they pass alone). This raises the ceiling,
    // it does not weaken any assertion.
    testTimeout: 20_000,
  },
});

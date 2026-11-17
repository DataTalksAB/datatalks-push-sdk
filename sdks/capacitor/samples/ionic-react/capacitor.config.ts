import type { CapacitorConfig } from '@capacitor/cli';

const config: CapacitorConfig = {
  appId: 'se.datatalks.sandbox.ionic',
  appName: 'DT Ionic',
  webDir: 'dist',
  plugins: {
    DataTalksPush: {
      // Read by `npx cap sync`: DATATALKS_PUSH_APP_KEY=dtpk_prd_test_… npx cap sync. Without a key the SDK stays off.
      appKey: process.env.DATATALKS_PUSH_APP_KEY ?? '',
      // The app routes a push's link itself, from notificationOpened (src/PushEvents.tsx).
      openLinks: false,
    },
  },
};

export default config;

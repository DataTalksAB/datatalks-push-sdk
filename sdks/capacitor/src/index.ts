import { registerPlugin } from '@capacitor/core';

import type { DataTalksPushPlugin } from './definitions';

const DataTalksPush = registerPlugin<DataTalksPushPlugin>('DataTalksPush', {
  web: () => import('./web').then((m) => new m.DataTalksPushWeb()),
});

export * from './definitions';
export { DataTalksPush };

import { WebPlugin } from '@capacitor/core';

import type { DataTalksPushPlugin, PermissionStatus } from './definitions';

/** Push needs the native SDKs: in a browser every call is refused as unimplemented. */
export class DataTalksPushWeb extends WebPlugin implements DataTalksPushPlugin {
  async checkPermissions(): Promise<PermissionStatus> {
    throw this.unimplemented('Data Talks push runs on Android and iOS only.');
  }

  async requestPermissions(): Promise<PermissionStatus> {
    throw this.unimplemented('Data Talks push runs on Android and iOS only.');
  }

  async identify(): Promise<void> {
    throw this.unimplemented('Data Talks push runs on Android and iOS only.');
  }

  async logout(): Promise<void> {
    throw this.unimplemented('Data Talks push runs on Android and iOS only.');
  }

  async setFcmToken(): Promise<void> {
    throw this.unimplemented('Data Talks push runs on Android and iOS only.');
  }

  async setMarketingOptIn(): Promise<void> {
    throw this.unimplemented('Data Talks push runs on Android and iOS only.');
  }

  async deleteLocalData(): Promise<void> {
    throw this.unimplemented('Data Talks push runs on Android and iOS only.');
  }
}

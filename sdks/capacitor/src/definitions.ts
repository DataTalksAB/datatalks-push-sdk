/// <reference types="@capacitor/cli" />

import type { PermissionState, PluginListenerHandle } from '@capacitor/core';

declare module '@capacitor/cli' {
  export interface PluginsConfig {
    /** Read by the native side at launch, so the SDK starts before the web app has loaded. */
    DataTalksPush?: {
      /** The app's publishable key from the portal, `dtpk_…`. Without it the SDK stays off. */
      appKey?: string;
      /**
       * Default true: the SDK opens a push's link, as in a native app. False suits an app that routes in JS: a tap only opens
       * the app, and the link reaches `notificationOpened`.
       */
      openLinks?: boolean;
      /** Replaces the host the key selects. Only for testing against a local ingress. */
      baseUrl?: string;
    };
  }
}

export interface PermissionStatus {
  /** `prompt` until the app asks (iOS, and Android 13 and later). */
  receive: PermissionState;
}

export interface RequestPermissionsOptions {
  /** iOS: ask for provisional authorization, which shows no prompt and delivers quietly. Ignored on Android. */
  provisional?: boolean;
}

export interface IdentifyOptions {
  /** Your id for the user: the same value as the identity token's `sub`. */
  externalId?: string;
  email?: string;
  /** The token your backend signed for this user. When the push app requires verified identity, a call without one is refused. */
  identityToken?: string;
}

export interface MarketingOptInOptions {
  optIn: boolean;
}

export interface FcmTokenOptions {
  token: string;
}

export interface NotificationOpenedEvent {
  deepLink?: string;
  data?: Record<string, unknown>;
}

/** A Data Talks push. On iOS, only while the app is open; otherwise the system shows it. */
export interface MessageReceivedEvent {
  uid?: string;
  title?: string;
  body?: string;
  /** The picture's https URL. On iOS, the notification service extension (`DataTalksPushExtension`) shows it. */
  imageUrl?: string;
  deepLink?: string;
  data?: Record<string, unknown>;
}

export interface IdentityResultEvent {
  verified: boolean;
  /** Set when the identify was refused. It isn't retried: call `identify` again at the next sign-in. */
  errorCode?: string;
  /** Why an identity token failed. It never says whether a profile was found. */
  errorDetail?: string;
}

/**
 * Calls resolve at once: the native SDK does the work in the background and retries it, and answers arrive as events.
 */
export interface DataTalksPushPlugin {
  checkPermissions(): Promise<PermissionStatus>;

  /** Shows the system prompt where one exists, and resolves with the answer. */
  requestPermissions(options?: RequestPermissionsOptions): Promise<PermissionStatus>;

  /**
   * Links this install to the signed-in user; the answer comes as an `identityResult` event. Repeating the same `externalId` and
   * `email` (with or without a token, as before) on the same UTC day sends nothing: the event repeats that day's answer, which says
   * nothing about this call's token. A token-only identify is always sent.
   */
  identify(options: IdentifyOptions): Promise<void>;

  /** Unlinks this install from its user. The install stays registered. */
  logout(): Promise<void>;

  /**
   * For apps whose iOS pushes go through their own Firebase project (transport FCM in the portal): pass the FCM registration token
   * each time Firebase reports it. Not needed when the AppDelegate posts the token as Capacitor's Firebase setup does. On Android the
   * SDK reads the token itself, so the call does nothing there.
   */
  setFcmToken(options: FcmTokenOptions): Promise<void>;

  /** Records the user's in-app marketing choice on this device. Transactional pushes aren't affected. */
  setMarketingOptIn(options: MarketingOptInOptions): Promise<void>;

  /** Deletes this install and everything the SDK keeps on the device. The SDK starts a new install at the next launch. */
  deleteLocalData(): Promise<void>;

  /** A tap on a notification. A tap that started the app waits until the first listener is added. */
  addListener(eventName: 'notificationOpened', listenerFunc: (event: NotificationOpenedEvent) => void): Promise<PluginListenerHandle>;

  /** A Data Talks push arrived: always on Android, only while the app is open on iOS. */
  addListener(eventName: 'messageReceived', listenerFunc: (event: MessageReceivedEvent) => void): Promise<PluginListenerHandle>;

  /** The service answered an `identify`. */
  addListener(eventName: 'identityResult', listenerFunc: (event: IdentityResultEvent) => void): Promise<PluginListenerHandle>;

  removeAllListeners(): Promise<void>;
}

import { useEffect, useRef } from 'react';
import { useIonRouter } from '@ionic/react';
import { DataTalksPush } from '@datatalks/push-capacitor';
import { addEvent } from './events';

/** The guide's listener (guide-ionic-react.md, step 5), plus the lines the demo shows in its events list. */
export function PushEvents() {
  // useIonRouter returns a new object on every render: a ref keeps the latest, so the listeners are added only once.
  const ionRouter = useIonRouter();
  const router = useRef(ionRouter);
  useEffect(() => {
    router.current = ionRouter;
  });

  useEffect(() => {
    const opened = DataTalksPush.addListener('notificationOpened', ({ deepLink, data }) => {
      addEvent(`Opened: ${deepLink ?? 'the app'}, data: ${data ? JSON.stringify(data) : 'none'}`);
      const route = deepLink ? routeFor(deepLink) : undefined;
      if (route) router.current.push(route);
    });
    const identity = DataTalksPush.addListener('identityResult', ({ verified, errorCode, errorDetail }) => {
      if (errorCode) console.warn('Data Talks refused the identify', errorCode, errorDetail);
      addEvent(errorCode ? `Identify refused: ${errorCode} ${errorDetail ?? ''}`.trim() : `Identify accepted, verified: ${verified}`);
    });
    const received = DataTalksPush.addListener('messageReceived', ({ uid, title, body }) => {
      addEvent(`Message ${uid ?? 'without an id'}${title || body ? `: ${[title, body].filter(Boolean).join(' ')}` : ''}`);
    });
    return () => {
      opened.then((handle) => handle.remove());
      identity.then((handle) => handle.remove());
      received.then((handle) => handle.remove());
    };
  }, []);

  return null;
}

// https://app.example.com/tickets/1042 and myapp://tickets/1042 both become /tickets/1042; a link that isn't a URL leaves
// the app where it opened. A custom scheme is parsed as https because older WebViews don't split it into host and path
// (`new URL('myapp://tickets/1042').host` is empty there). Leading slashes collapse to one: a path starting with // would
// name another host, which the router refuses.
function routeFor(deepLink: string): string | undefined {
  try {
    const url = /^https?:/i.test(deepLink) ? new URL(deepLink) : new URL(deepLink.replace(/^[a-z][a-z0-9+.-]*:\/*/i, 'https://app/'));
    return '/' + url.pathname.replace(/^\/+/, '') + url.search;
  } catch {
    return undefined;
  }
}

import { useEffect, useState } from 'react';
import { Capacitor } from '@capacitor/core';
import { IonButton, IonContent, IonHeader, IonInput, IonItem, IonLabel, IonPage, IonToggle, IonToolbar, useIonViewWillEnter } from '@ionic/react';
import { DataTalksPush } from '@datatalks-ab/push-capacitor';
import { addEvent, useEvents } from '../events';

/**
 * The sandbox screen, as in the other demos: permission, identify (with a token pasted from the portal's "Test a token"),
 * log out, consent, delete, and what the SDK reports. The key comes from capacitor.config.ts.
 */
export function Home() {
  const events = useEvents();
  const [permission, setPermission] = useState('unknown');
  const [externalId, setExternalId] = useState('');
  const [email, setEmail] = useState('');
  const [identityToken, setIdentityToken] = useState('');

  const run = (call: () => Promise<unknown>) => call().catch((error: Error) => addEvent(`Failed: ${error.message}`));
  const checkPermission = () => run(async () => setPermission((await DataTalksPush.checkPermissions()).receive));

  // The permission can change in the system's settings while the app is away.
  useIonViewWillEnter(() => checkPermission());
  useEffect(() => {
    const onVisible = () => !document.hidden && checkPermission();
    document.addEventListener('visibilitychange', onVisible);
    return () => document.removeEventListener('visibilitychange', onVisible);
  }, []);

  const requestPermission = () =>
    run(async () => {
      const { receive } = await DataTalksPush.requestPermissions();
      setPermission(receive);
      addEvent(`Permission: ${receive}`);
    });

  const identify = () =>
    run(() =>
      DataTalksPush.identify({
        externalId: externalId.trim() || undefined,
        email: email.trim() || undefined,
        identityToken: identityToken.trim() || undefined,
      }),
    );

  return (
    <IonPage>
      <IonHeader>
        <IonToolbar className="brand">
          <div className="brand-row">
            <Mark />
            <div className="titles">
              <h1>Data Talks</h1>
              <p>Push SDK demo · Ionic {Capacitor.getPlatform() === 'ios' ? 'iOS' : 'Android'}</p>
            </div>
            <span className="badge">SANDBOX</span>
          </div>
        </IonToolbar>
      </IonHeader>

      <IonContent className="sandbox">
        <section className="card">
          <h2>App</h2>
          <p className="hint">
            The app key comes from <code>DATATALKS_PUSH_APP_KEY</code> when <code>npx cap sync</code> runs (capacitor.config.ts), so the
            SDK starts before this page loads.
          </p>
          <div className="row">
            <IonButton shape="round" onClick={requestPermission}>
              Ask for permission
            </IonButton>
            <IonButton shape="round" fill="outline" onClick={checkPermission}>
              Check permission
            </IonButton>
          </div>
          <p className="hint">Permission: {permission}</p>
        </section>

        <section className="card">
          <h2>User</h2>
          {/* Ionic 6: ionChange carries the value, at every keystroke. */}
          <IonInput className="field" placeholder="External id" value={externalId} onIonChange={(e) => setExternalId(e.detail.value ?? '')} />
          <IonInput className="field" placeholder="Email" type="email" value={email} onIonChange={(e) => setEmail(e.detail.value ?? '')} />
          <IonInput className="field" placeholder="Identity token" value={identityToken} onIonChange={(e) => setIdentityToken(e.detail.value ?? '')} />
          <p className="hint">Paste a token from the portal's Test a token, or leave it empty for an unverified identify.</p>
          <div className="row">
            <IonButton shape="round" onClick={identify}>
              Identify
            </IonButton>
            <IonButton shape="round" fill="outline" onClick={() => run(() => DataTalksPush.logout())}>
              Log out
            </IonButton>
          </div>
        </section>

        <section className="card">
          <h2>Device</h2>
          <IonItem lines="none" className="toggle">
            <IonToggle slot="start" checked onIonChange={(e) => run(() => DataTalksPush.setMarketingOptIn({ optIn: e.detail.checked }))} />
            <IonLabel>Marketing pushes</IonLabel>
          </IonItem>
          <div className="row">
            <IonButton shape="round" fill="outline" onClick={() => run(() => DataTalksPush.deleteLocalData())}>
              Delete local data
            </IonButton>
          </div>
          <p className="hint">Deletes this install on the service too. The next launch starts a new one.</p>
        </section>

        <section className="card">
          <h2>Events</h2>
          {events.length === 0 && <p className="hint">Nothing yet. Taps, pushes and identify answers show here.</p>}
          <ul className="events">
            {events.map((line, index) => (
              <li key={events.length - index}>{line}</li>
            ))}
          </ul>
        </section>
      </IonContent>
    </IonPage>
  );
}

function Mark() {
  return (
    <svg viewBox="0 0 61 61" aria-hidden="true" className="mark">
      <path
        fill="#F35625"
        d="M2.6,58.4V46.3C10.9,36,17.5,31.1,22.5,31.2c4.7,0.1,8.2,4.7,11.8,9.6c2.9,3.9,5.9,7.9,9.9,10.3 c2.3,1.4,4.8,2.1,7.4,2.1c2.1,0,4.4-0.5,6.7-1.4v6.6H2.6z M58.4,2.6V22c-4.1,8.1-8.6,12.6-13.6,13.3c-6,0.8-10.9-4.1-12.3-5.6 l-0.1-0.1c-1.5-1.4-3.1-3.7-4.9-6.1C22.2,16,14.9,6,2.6,9.9V2.6H58.4z M58.4,37c-3.4,4.2-8,3.7-14.3,0.9c0.4,0,0.7,0,1.1-0.1 c4.9-0.7,9.3-4.2,13.2-10.5V37z M34.3,36.1c6.4,3.4,12.6,6.6,17.8,6.6c2.3,0,4.3-0.6,6.2-2V49c-11.1,4.8-16.4-2.3-21.9-9.7 c-0.8-1.1-1.7-2.3-2.6-3.4C34,36,34.2,36,34.3,36.1L34.3,36.1z M2.6,29.5c5.2-2.3,10.7-2,16.1-0.4c-4.6,1.5-9.9,5.7-16.1,13V29.5 z M2.6,12.7C13.6,8.6,19.9,17.3,25.4,25c1.6,2.3,3.2,4.4,4.7,6c-8.8-4.4-18.2-7.9-27.5-4.3V12.7z"
      />
    </svg>
  );
}

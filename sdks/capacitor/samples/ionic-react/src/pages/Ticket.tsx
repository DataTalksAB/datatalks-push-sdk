import { IonBackButton, IonButtons, IonContent, IonHeader, IonPage, IonTitle, IonToolbar } from '@ionic/react';
import { useParams } from 'react-router-dom';

/** The page a push's link routes to: it shows that notificationOpened reached the Ionic router. */
export function Ticket() {
  const { id } = useParams<{ id: string }>();

  return (
    <IonPage>
      <IonHeader>
        <IonToolbar className="brand">
          <IonButtons slot="start">
            <IonBackButton defaultHref="/" />
          </IonButtons>
          <IonTitle>Ticket {id}</IonTitle>
        </IonToolbar>
      </IonHeader>
      <IonContent className="sandbox">
        <section className="card">
          <h2>Opened from a push</h2>
          <p className="hint">
            The push's link came to <code>notificationOpened</code>, and the app routed it here: <code>/tickets/{id}</code>.
          </p>
        </section>
      </IonContent>
    </IonPage>
  );
}

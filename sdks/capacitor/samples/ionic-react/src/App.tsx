import { IonApp, IonRouterOutlet, setupIonicReact } from '@ionic/react';
import { IonReactRouter } from '@ionic/react-router';
import { Route } from 'react-router-dom';
import { PushEvents } from './PushEvents';
import { Home } from './pages/Home';
import { Ticket } from './pages/Ticket';

import '@ionic/react/css/core.css';
import '@ionic/react/css/normalize.css';
import '@ionic/react/css/structure.css';
import '@ionic/react/css/typography.css';
import './theme.css';

setupIonicReact();

export function App() {
  return (
    <IonApp>
      <IonReactRouter>
        {/* Inside the router, so a tap can navigate. A tap that launched the app arrives once it listens. */}
        <PushEvents />
        <IonRouterOutlet>
          <Route exact path="/" component={Home} />
          {/* Where a push with the link https://example.com/tickets/1042, or dtionic://tickets/1042, lands. */}
          <Route exact path="/tickets/:id" component={Ticket} />
        </IonRouterOutlet>
      </IonReactRouter>
    </IonApp>
  );
}

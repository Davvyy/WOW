import { Refine } from '@refinedev/core';
import routerProvider from '@refinedev/react-router';
import { BrowserRouter, Navigate, Route, Routes } from 'react-router';
import { ChallengeLayout, Shell } from './components/Shell';
import { ConsoleProvider } from './context';
import { getApi } from './data';
import { createRefineDataProvider } from './data/refineProvider';
import { NewChallenge } from './pages/NewChallenge';
import { OP0Challenges } from './pages/OP0Challenges';
import { OP1Settings } from './pages/OP1Settings';
import { OP2Participants } from './pages/OP2Participants';
import { OP3Reviews } from './pages/OP3Reviews';
import { OP4Results } from './pages/OP4Results';
import { AuthGate } from './pages/Login';

export default function App() {
  const api = getApi();
  return (
    <BrowserRouter>
      <Refine
        routerProvider={routerProvider}
        dataProvider={createRefineDataProvider(api)}
        resources={[{ name: 'challenges', list: '/' }]}
        options={{ disableTelemetry: true, syncWithLocation: false }}
      >
        <AuthGate api={api}>
          <ConsoleProvider api={api}>
            <Routes>
              <Route element={<Shell />}>
                <Route index element={<OP0Challenges />} />
                <Route path="new" element={<NewChallenge />} />
                <Route path="c/:cid" element={<ChallengeLayout />}>
                  <Route index element={<Navigate to="settings" replace />} />
                  <Route path="settings" element={<OP1Settings />} />
                  <Route path="participants" element={<OP2Participants />} />
                  <Route path="reviews" element={<OP3Reviews />} />
                  <Route path="results" element={<OP4Results />} />
                </Route>
                <Route path="*" element={<Navigate to="/" replace />} />
              </Route>
            </Routes>
          </ConsoleProvider>
        </AuthGate>
      </Refine>
    </BrowserRouter>
  );
}

import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import App from './App';
// 폰트는 CDN 대신 번들(OFL / Apache-2.0): 본문 IBM Plex Sans KR, 숫자 Barlow Semi Condensed, 아이콘 Material Symbols Rounded
import '@fontsource/ibm-plex-sans-kr/400.css';
import '@fontsource/ibm-plex-sans-kr/500.css';
import '@fontsource/ibm-plex-sans-kr/600.css';
import '@fontsource/ibm-plex-sans-kr/700.css';
import '@fontsource/barlow-semi-condensed/500.css';
import '@fontsource/barlow-semi-condensed/600.css';
import '@fontsource/barlow-semi-condensed/700.css';
import 'material-symbols/rounded.css';
import './styles.css';

createRoot(document.getElementById('root')!).render(<StrictMode><App /></StrictMode>);

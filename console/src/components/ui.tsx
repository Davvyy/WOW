import { useEffect, useRef, type ReactNode } from 'react';

export function Ms({ name, cls = '' }: { name: string; cls?: string }) {
  return <span className={`ms ${cls}`} aria-hidden="true">{name}</span>;
}

export type Kind = 'neutral' | 'brand' | 'review' | 'good' | 'warn' | 'critical' | 'outline';

export function Chip({ kind = 'neutral', icon, children }: { kind?: Kind; icon?: string; children: ReactNode }) {
  return <span className={`chip ${kind}`}>{icon ? <Ms name={icon} /> : null}{children}</span>;
}

export function Banner({ kind, icon, children, action, lg, role }: { kind: Kind; icon: string; children: ReactNode; action?: ReactNode; lg?: boolean; role?: string }) {
  return (
    <div className={`banner ${kind}${lg ? ' lg' : ''}`} role={role}>
      <Ms name={icon} />
      <div className="grow">{children}</div>
      {action}
    </div>
  );
}

export function Avatar({ name }: { name: string }) {
  const colors = ['c1', 'c2', 'c3', 'c4', 'c5', 'c6'];
  const c = colors[[...name].reduce((a, ch) => a + ch.charCodeAt(0), 0) % colors.length];
  return <span className={`sm-avatar avatar ${c}`} aria-hidden="true">{name[0]}</span>;
}

export function Fill4({ n }: { n: number }) {
  return <span className="fill4" aria-hidden="true">{[0, 1, 2, 3].map((i) => <i key={i} className={i < n ? '' : 'off'} />)}</span>;
}

export function PageHead({ id, title, lead, acts }: { id: string; title: string; lead?: string; acts?: ReactNode }) {
  return (
    <div className="pagehead">
      <div>
        <h1><span className="id">{id}</span>{title}</h1>
        {lead ? <p className="lead">{lead}</p> : null}
      </div>
      {acts ? <div className="acts">{acts}</div> : null}
    </div>
  );
}

export function Modal({ id, title, children, acts, onClose }: { id: string; title: ReactNode; children: ReactNode; acts: ReactNode; onClose: () => void }) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const prev = document.activeElement as HTMLElement | null;
    const f = ref.current?.querySelector<HTMLElement>('input:not([disabled]), textarea, select, button:not([disabled])');
    (f ?? ref.current)?.focus({ preventScroll: true });
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose(); };
    document.addEventListener('keydown', onKey);
    document.body.style.overflow = 'hidden';
    return () => { document.removeEventListener('keydown', onKey); document.body.style.overflow = ''; prev?.focus?.(); };
  }, [onClose]);
  return (
    <div className="scrim" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <div className="modal" role="dialog" aria-modal="true" aria-labelledby={`${id}-t`} id={id} ref={ref} tabIndex={-1}>
        <h2 id={`${id}-t`}>{title}</h2>
        {children}
        <div className="acts">{acts}</div>
      </div>
    </div>
  );
}

export function Drawer({ label, onClose, head, children }: { label: string; onClose: () => void; head: ReactNode; children: ReactNode }) {
  const ref = useRef<HTMLElement>(null);
  useEffect(() => {
    const prev = document.activeElement as HTMLElement | null;
    ref.current?.focus({ preventScroll: true });
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose(); };
    document.addEventListener('keydown', onKey);
    document.body.style.overflow = 'hidden';
    return () => { document.removeEventListener('keydown', onKey); document.body.style.overflow = ''; prev?.focus?.(); };
  }, [onClose]);
  return (
    <div className="scrim right" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <aside className="drawer" role="dialog" aria-modal="true" aria-label={label} ref={ref} tabIndex={-1}>
        <div className="dhead">
          {head}
          <button className="iconbtn" onClick={onClose} aria-label="드로어 닫기"><Ms name="close" /></button>
        </div>
        <div className="dbody">{children}</div>
      </aside>
    </div>
  );
}

export function Loading({ label = '불러오는 중이에요' }: { label?: string }) {
  return <div className="empty" role="status"><Ms name="progress_activity" /><p className="body">{label}</p></div>;
}

export function ErrorBox({ error, retry }: { error: Error; retry?: () => void }) {
  return (
    <Banner kind="critical" icon="error" role="alert" action={retry ? <button className="btn sm quiet" onClick={retry}>다시 불러오기</button> : null}>
      <b>불러오지 못했어요</b><br /><span className="cap">{error.message}</span>
    </Banner>
  );
}

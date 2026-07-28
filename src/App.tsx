import { useEffect, useMemo, useState } from "react";
import { cmd, onState, type Alarm, type ClockState, type Timer } from "./bridge";

export default function App() {
  const [state, setState] = useState<ClockState>({ alarms: [], timers: [] });
  const [now, setNow] = useState(new Date());

  useEffect(() => {
    let un: (() => void) | undefined;
    onState(setState).then((f) => (un = f));
    cmd({ cmd: "state" }).then(setState).catch(() => {});
    const t = setInterval(() => setNow(new Date()), 1000);
    return () => {
      un?.();
      clearInterval(t);
    };
  }, []);

  const run = (req: unknown) => cmd(req).then(setState).catch(() => {});

  return (
    <div className="app">
      <ClockFace now={now} />
      <Section title="Alarms">
        <AddAlarm onAdd={run} />
        {state.alarms.length === 0 && <p className="empty">No alarms yet.</p>}
        {state.alarms.map((a) => (
          <AlarmRow key={a.id} a={a} onCancel={() => run({ cmd: "cancel", id: a.id })} onToggle={() => run({ cmd: "toggle", id: a.id })} />
        ))}
      </Section>
      <Section title="Timers">
        <AddTimer onAdd={run} />
        {state.timers.length === 0 && <p className="empty">No timers running.</p>}
        {state.timers.map((t) => (
          <TimerRow key={t.id} t={t} onCancel={() => run({ cmd: "cancel", id: t.id })} />
        ))}
      </Section>
    </div>
  );
}

function ClockFace({ now }: { now: Date }) {
  const time = now.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
  const date = now.toLocaleDateString([], { weekday: "long", month: "long", day: "numeric" });
  return (
    <div className="face">
      <div className="time">{time}</div>
      <div className="date">{date}</div>
    </div>
  );
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="section">
      <h2>{title}</h2>
      {children}
    </section>
  );
}

function AddAlarm({ onAdd }: { onAdd: (r: unknown) => void }) {
  const [when, setWhen] = useState("07:30");
  const [label, setLabel] = useState("");
  const [repeat, setRepeat] = useState("once");
  const submit = () => {
    onAdd({ cmd: "alarm", when, label, repeat });
    setLabel("");
  };
  return (
    <div className="add">
      <input className="i-time" type="time" value={when} onChange={(e) => setWhen(e.target.value)} />
      <input className="i-label" placeholder="label" value={label} onChange={(e) => setLabel(e.target.value)} onKeyDown={(e) => e.key === "Enter" && submit()} />
      <select value={repeat} onChange={(e) => setRepeat(e.target.value)}>
        <option value="once">Once</option>
        <option value="daily">Every day</option>
        <option value="weekdays">Weekdays</option>
        <option value="weekends">Weekends</option>
      </select>
      <button className="primary" onClick={submit}>Add</button>
    </div>
  );
}

function AlarmRow({ a, onCancel, onToggle }: { a: Alarm; onCancel: () => void; onToggle: () => void }) {
  return (
    <div className={"row" + (a.enabled ? "" : " off")}>
      <button className="dot" onClick={onToggle} title={a.enabled ? "on" : "off"} />
      <div className="grow">
        <div className="line1">
          <span className="big">{a.time}</span>
          {a.label && <span className="lbl">{a.label}</span>}
        </div>
        <div className="line2">
          {a.repeat !== "Once" && <span>{a.repeat}</span>}
          <span>→ {a.wakes}</span>
          {a.owner && <span>by {a.owner}</span>}
          {a.note && <span className="note">“{a.note}”</span>}
        </div>
      </div>
      <button className="x" onClick={onCancel}>✕</button>
    </div>
  );
}

function AddTimer({ onAdd }: { onAdd: (r: unknown) => void }) {
  const [dur, setDur] = useState("5m");
  const [label, setLabel] = useState("");
  const submit = () => {
    onAdd({ cmd: "timer", dur, label });
    setLabel("");
  };
  return (
    <div className="add">
      <input className="i-dur" placeholder="10m · 1h30m · 90s" value={dur} onChange={(e) => setDur(e.target.value)} />
      <input className="i-label" placeholder="label" value={label} onChange={(e) => setLabel(e.target.value)} onKeyDown={(e) => e.key === "Enter" && submit()} />
      <button className="primary" onClick={submit}>Start</button>
    </div>
  );
}

function TimerRow({ t, onCancel }: { t: Timer; onCancel: () => void }) {
  const pct = useMemo(() => (t.total > 0 ? Math.max(0, Math.min(1, t.remaining / t.total)) : 0), [t.remaining, t.total]);
  return (
    <div className="row">
      <div className="ring" style={{ background: `conic-gradient(var(--accent) ${pct * 360}deg, var(--track) 0)` }}>
        <div className="ring-in" />
      </div>
      <div className="grow">
        <div className="line1">
          <span className="big mono">{t.done ? "Done" : t.remainingText}</span>
          {t.label && <span className="lbl">{t.label}</span>}
        </div>
        {t.owner && <div className="line2"><span>by {t.owner}</span></div>}
      </div>
      <button className="x" onClick={onCancel}>✕</button>
    </div>
  );
}

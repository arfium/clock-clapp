// The Alarms tab, to Apple's anatomy (`AlarmsView.swift`). `MTAAlarmTableViewCell` has
// exactly three visible parts — `_digitalClockLabel`, `_detailLabel`, `_enabledSwitch` —
// laid out as [time + detail] · spacer · [switch], inside an inset-grouped card.
//
// Two details are where knockoffs give themselves away:
//   • A switched-OFF alarm changes TEXT COLOUR. It is never `.opacity()` on the row —
//     that fades the switch too and reads as "loading/broken" rather than "off".
//   • The switch is GREEN, never the app accent.

import { useEffect, useState, type ReactNode } from "react";
import type { Alarm, AgentRow } from "./bridge";
import { DAY_LETTER, hm, splitTime } from "./format";
import { IconNote, IconPlus, IconEllipsis, IconUpDown } from "./icons";
import { TimeWheel } from "./WheelPicker";
import {
  AgentTag,
  AppleSwitch,
  GroupedCard,
  Hairline,
  MenuPopup,
  PlainButton,
  PushButton,
  SectionHeader,
  Sheet,
  type MenuItem,
} from "./ui";

export type Run = (req: Record<string, unknown>) => void;

const nameFor = (agents: AgentRow[], id: string) => agents.find((a) => a.id === id)?.name ?? id;

/// The title + "＋" band. Apple puts these in the window toolbar; we draw the same
/// relationship in-content since this window hosts its own chrome.
export function AddBar({ title, add }: { title: string; add?: () => void }) {
  return (
    <div className="addbar">
      <div className="addbar-title">{title}</div>
      {add && (
        <PlainButton onClick={add} title={`New ${title.toLowerCase()}`}>
          <IconPlus size={15} />
        </PlainButton>
      )}
    </div>
  );
}

export function AlarmsView({
  alarms,
  agents,
  run,
}: {
  alarms: Alarm[];
  agents: AgentRow[];
  run: Run;
}) {
  const [adding, setAdding] = useState(false);
  const [editing, setEditing] = useState<Alarm | null>(null);

  // Keep the open sheet pinned to the live alarm (the CLI may have changed it).
  useEffect(() => {
    if (editing && !alarms.some((a) => a.id === editing.id)) setEditing(null);
  }, [alarms, editing]);

  return (
    <div className="tab">
      <AddBar title="Alarms" add={() => setAdding(true)} />

      {alarms.length === 0 ? (
        // Apple's empty state is one line of gray text — no icon, no description, no
        // button (the loctable has NO_ALARMS and no sibling strings at all).
        <div className="empty-state">No Alarms</div>
      ) : (
        <div className="scroll">
          <div className="card-wrap">
            <GroupedCard>
              {alarms.map((a, i) => (
                <div key={a.id}>
                  <AlarmRow alarm={a} run={run} onEdit={() => setEditing(a)} />
                  {i < alarms.length - 1 && <Hairline />}
                </div>
              ))}
            </GroupedCard>
          </div>
        </div>
      )}

      {adding && (
        <AlarmSheet agents={agents} run={run} editing={null} onClose={() => setAdding(false)} />
      )}
      {editing && (
        <AlarmSheet agents={agents} run={run} editing={editing} onClose={() => setEditing(null)} />
      )}
    </div>
  );
}

function AlarmRow({
  alarm,
  run,
  onEdit,
}: {
  alarm: Alarm;
  run: Run;
  onEdit: () => void;
}) {
  const [menuAt, setMenuAt] = useState<{ x: number; y: number } | null>(null);
  const on = alarm.enabled;
  const [big, ampm] = splitTime(hm(alarm.hour, alarm.minute));

  // Identical for the ⋯ button and right-click.
  const items: MenuItem[] = [
    { label: "Edit Alarm…", onSelect: onEdit },
    { label: on ? "Turn Off" : "Turn On", onSelect: () => run({ cmd: "toggle", id: alarm.id }) },
    { divider: true },
    { label: "Delete Alarm", destructive: true, onSelect: () => run({ cmd: "cancel", id: alarm.id }) },
  ];

  return (
    <div
      className="alarm-row"
      onDoubleClick={onEdit}
      onContextMenu={(e) => {
        e.preventDefault();
        setMenuAt({ x: e.clientX, y: e.clientY });
      }}
    >
      <div className="alarm-text">
        <div className={"alarm-time" + (on ? "" : " off")}>
          <span className="big tnum">{big}</span>
          {ampm && <span className="ampm">{ampm}</span>}
        </div>
        {/* Apple's ALARM_DETAIL_FORMAT = "%1$@, %2$@" → "{label}, {repeat}", composed in
            the store so `clock list` says the same thing. */}
        <div className="alarm-detail">
          <span>{alarm.detail}</span>
          {alarm.note && (
            <span className={"note-glyph" + (on ? "" : " off")} title={alarm.note}>
              <IconNote size={10} />
            </span>
          )}
          {/* Who it wakes — only when the alarm targets specific agents (a default
              "everyone" alarm stays clean, Apple-style). */}
          {alarm.targets.length > 0 && (
            <>
              <span className="dot-sep">·</span>
              <AgentTag name={alarm.wakesShort} dimmed={!on} />
            </>
          )}
        </div>
      </div>

      <AppleSwitch
        checked={on}
        onChange={() => run({ cmd: "toggle", id: alarm.id })}
        title={on ? "Turn Off" : "Turn On"}
      />

      <button
        type="button"
        className="row-menu"
        title="Alarm actions"
        onClick={(e) => {
          e.stopPropagation();
          const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
          setMenuAt({ x: r.left, y: r.bottom + 2 });
        }}
        onDoubleClick={(e) => e.stopPropagation()}
      >
        <IconEllipsis size={13} />
      </button>

      {menuAt && <MenuPopup at={menuAt} items={items} onClose={() => setMenuAt(null)} />}
    </div>
  );
}

/// Add or edit an alarm. Apple's `MTAAlarmEditViewController` is one grouped table
/// titled "Add Alarm" / "Edit Alarm", with Delete Alarm present only when editing.
function AlarmSheet({
  editing,
  agents,
  run,
  onClose,
}: {
  editing: Alarm | null;
  agents: AgentRow[];
  run: Run;
  onClose: () => void;
}) {
  const [hour, setHour] = useState(editing ? editing.hour : 7);
  const [minute, setMinute] = useState(editing ? editing.minute : 0);
  const [label, setLabel] = useState(editing?.label ?? "");
  const [note, setNote] = useState(editing?.note ?? "");
  const [days, setDays] = useState<number[]>(editing ? [...editing.days] : []);
  const [wake, setWake] = useState(editing ? editing.wake : true);
  const [targets, setTargets] = useState<string[]>(editing ? [...editing.targets] : []);
  const [pickAt, setPickAt] = useState<{ x: number; y: number } | null>(null);

  // The drum sends hour+minute (the store also accepts the CLI's "7:30am"); `days` is
  // the pill set; `targets` holds agent IDS, empty = broadcast. An `edit` keeps every
  // field it is not sent, and re-arms the minute guard on the Rust side.
  const save = () => {
    const req = { hour, minute, label: label.trim(), note: note.trim(), days, wake, targets };
    run(editing ? { cmd: "edit", id: editing.id, ...req } : { cmd: "alarm", ...req });
    onClose();
  };

  const toggleDay = (d: number) =>
    setDays((cur) => (cur.includes(d) ? cur.filter((x) => x !== d) : [...cur, d].sort((a, b) => a - b)));

  // (id, name) options: the roster ∪ any already-chosen agent no longer in it (set from
  // the CLI, or disconnected) so it still shows and can be toggled off.
  const seen = new Set<string>();
  const pickable: [string, string][] = [];
  for (const ag of agents) if (!seen.has(ag.id)) (seen.add(ag.id), pickable.push([ag.id, ag.name]));
  for (const id of targets) if (!seen.has(id)) (seen.add(id), pickable.push([id, nameFor(agents, id)]));
  pickable.sort((a, b) => a[1].toLowerCase().localeCompare(b[1].toLowerCase()));

  const wakesLabel =
    targets.length === 0
      ? "Everyone"
      : targets
          .map((id) => nameFor(agents, id))
          .sort()
          .join(", ");

  const pickItems: MenuItem[] = [
    { label: "Everyone", checked: targets.length === 0, onSelect: () => setTargets([]) },
    ...(pickable.length ? [{ divider: true } as MenuItem] : []),
    ...pickable.map(
      ([id, name]): MenuItem => ({
        label: name,
        checked: targets.includes(id),
        onSelect: () =>
          setTargets((cur) => (cur.includes(id) ? cur.filter((x) => x !== id) : [...cur, id])),
      })
    ),
  ];

  return (
    <Sheet open onClose={onClose} onDefault={save}>
      <div className="sheet-title">{editing ? "Edit Alarm" : "Add Alarm"}</div>

      {/* The title and the Cancel/Save row are pinned; only this scrolls, so the sheet
          still fits (and still has a reachable default button) at the 560pt minimum. */}
      <div className="sheet-body">
        <TimeWheel
          hour={hour}
          minute={minute}
          onChange={(h, m) => {
            setHour(h);
            setMinute(m);
          }}
        />

        <GroupedCard>
          <SheetRow title="Repeat">
            <div className="day-pills">
              {[1, 2, 3, 4, 5, 6, 7].map((d) => (
                <button
                  type="button"
                  key={d}
                  className={"day-pill" + (days.includes(d) ? " on" : "")}
                  onClick={() => toggleDay(d)}
                >
                  {DAY_LETTER[d]}
                </button>
              ))}
            </div>
          </SheetRow>
          <Hairline />
          <SheetRow title="Label:">
            <input
              className="field"
              placeholder="Alarm"
              value={label}
              onChange={(e) => setLabel(e.target.value)}
            />
          </SheetRow>
          <Hairline />
          <SheetRow title="Wake the agent">
            <AppleSwitch checked={wake} onChange={setWake} />
          </SheetRow>
          <Hairline />
          <SheetRow title="Wake which">
            <button
              type="button"
              className="agent-pick"
              title="Which agent(s) this alarm wakes — everyone, or a chosen few"
              onClick={(e) => {
                const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
                setPickAt({ x: r.left, y: r.bottom + 2 });
              }}
            >
              <span className="agent-pick-label">{wakesLabel}</span>
              <IconUpDown size={9} />
            </button>
          </SheetRow>
        </GroupedCard>

        {/* The note is the alarm's whole payload when it wakes an agent, so it gets room
            to breathe rather than a one-line field. */}
        <div className="note-block">
          <SectionHeader>Note</SectionHeader>
          <textarea className="note-editor" value={note} onChange={(e) => setNote(e.target.value)} />
          <div className="note-caption">
            {wake
              ? "Sent as the prompt for the turn this alarm wakes."
              : "Recorded with the alarm. No turn is started."}
          </div>
        </div>

        {editing && (
          <PlainButton
            tint="destructive"
            className="delete-alarm"
            onClick={() => {
              run({ cmd: "cancel", id: editing.id });
              onClose();
            }}
          >
            Delete Alarm
          </PlainButton>
        )}
      </div>

      <div className="sheet-buttons">
        <PushButton onClick={onClose}>Cancel</PushButton>
        <PushButton prominent tint="accent" onClick={save}>
          Save
        </PushButton>
      </div>

      {pickAt && (
        <MenuPopup at={pickAt} items={pickItems} onClose={() => setPickAt(null)} minWidth={160} />
      )}
    </Sheet>
  );
}

const SheetRow = ({ title, children }: { title: string; children: ReactNode }) => (
  <div className="sheet-row">
    <span className="sheet-row-title">{title}</span>
    <span className="sheet-row-trailing">{children}</span>
  </div>
);

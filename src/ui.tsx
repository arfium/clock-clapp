// The reusable atoms from `Theme.swift`: AppleSwitch, CircleButtonStyle,
// PlainTintStyle, GroupedCard, Hairline, SectionHeader, AgentTag — plus the two bits
// of Mac chrome SwiftUI gives for free and a webview does not: a sheet and a menu.

import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { IconCheck } from "./icons";

// MARK: - Text atoms

export const SectionHeader = ({ children }: { children: ReactNode }) => (
  <div className="section-header">{children}</div>
);

/// Never drawn after the final row (`Hairline`, inset 16 from the leading edge).
export const Hairline = () => <div className="hairline" />;

export const GroupedCard = ({ children }: { children: ReactNode }) => (
  <div className="card">{children}</div>
);

/// Names the agent an alarm wakes / a timer belongs to. Tinted text, never a capsule.
export const AgentTag = ({ name, dimmed = false }: { name: string; dimmed?: boolean }) => (
  <span className={"agent-tag" + (dimmed ? " dim" : "")}>{name}</span>
);

// MARK: - Controls

/// The alarm switch at the Mac's own 38×22 metrics — green, never the app accent.
export function AppleSwitch({
  checked,
  onChange,
  title,
}: {
  checked: boolean;
  onChange: (v: boolean) => void;
  title?: string;
}) {
  return (
    <button
      type="button"
      className={"switch" + (checked ? " on" : "")}
      role="switch"
      aria-checked={checked}
      title={title}
      onClick={(e) => {
        e.stopPropagation();
        onChange(!checked);
      }}
      onDoubleClick={(e) => e.stopPropagation()}
    >
      <span className="knob" />
    </button>
  );
}

/// The round button under the timer ring: label at full strength, disc at 20 % of the
/// same hue (10 % disabled). `neutral` breaks the hue match on purpose — Cancel.
export function CircleButton({
  label,
  tone,
  disabled,
  onClick,
}: {
  label: string;
  tone: "accent" | "go" | "neutral";
  disabled?: boolean;
  onClick?: () => void;
}) {
  return (
    <button type="button" className={`circle-btn ${tone}`} disabled={disabled} onClick={onClick}>
      {label}
    </button>
  );
}

/// A plain tinted text button — no chrome at all (`PlainTintStyle`).
export function PlainButton({
  children,
  tint = "accent",
  onClick,
  title,
  className = "",
}: {
  children: ReactNode;
  tint?: "accent" | "destructive";
  onClick?: () => void;
  title?: string;
  className?: string;
}) {
  return (
    <button type="button" className={`plain-btn ${tint} ${className}`} onClick={onClick} title={title}>
      {children}
    </button>
  );
}

/// Stock macOS push buttons: plain, and `.borderedProminent` tinted.
export function PushButton({
  children,
  onClick,
  prominent,
  tint = "accent",
  disabled,
}: {
  children: ReactNode;
  onClick?: () => void;
  prominent?: boolean;
  tint?: "accent" | "go";
  disabled?: boolean;
}) {
  return (
    <button
      type="button"
      className={"push" + (prominent ? ` prominent ${tint}` : "")}
      onClick={onClick}
      disabled={disabled}
    >
      {children}
    </button>
  );
}

// MARK: - Sheet

/// A macOS sheet: slides down from the titlebar, centred horizontally, and does NOT
/// dim the parent — the overlay only swallows clicks.
export function Sheet({
  open,
  onClose,
  onDefault,
  className = "",
  children,
}: {
  open: boolean;
  onClose: () => void;
  onDefault?: () => void;
  className?: string;
  children: ReactNode;
}) {
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.preventDefault();
        onClose();
      } else if (e.key === "Enter" && onDefault && !(e.target instanceof HTMLTextAreaElement)) {
        e.preventDefault();
        onDefault();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open, onClose, onDefault]);

  if (!open) return null;
  return (
    <div className="sheet-overlay">
      <div className={"sheet " + className} role="dialog" aria-modal="true">
        {children}
      </div>
    </div>
  );
}

// MARK: - Menu

export type MenuItem =
  | { divider: true }
  | { divider?: false; label: string; checked?: boolean; destructive?: boolean; onSelect: () => void };

/// A macOS pop-up menu, anchored at a point. Used by the row's ⋯ / right-click menu
/// and by the sheet's "Wake which" picker — the same control SwiftUI's `Menu` gives.
export function MenuPopup({
  at,
  items,
  onClose,
  minWidth = 0,
}: {
  at: { x: number; y: number };
  items: MenuItem[];
  onClose: () => void;
  minWidth?: number;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState(at);

  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const r = el.getBoundingClientRect();
    const x = Math.max(6, Math.min(at.x, window.innerWidth - r.width - 6));
    const y = Math.max(6, Math.min(at.y, window.innerHeight - r.height - 6));
    setPos({ x, y });
  }, [at.x, at.y]);

  useEffect(() => {
    const down = (e: MouseEvent) => {
      if (!ref.current?.contains(e.target as Node)) onClose();
    };
    const key = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("mousedown", down, true);
    window.addEventListener("keydown", key);
    return () => {
      window.removeEventListener("mousedown", down, true);
      window.removeEventListener("keydown", key);
    };
  }, [onClose]);

  return (
    <div className="menu" ref={ref} style={{ left: pos.x, top: pos.y, minWidth: minWidth || undefined }}>
      {items.map((it, i) =>
        it.divider ? (
          <div className="menu-sep" key={i} />
        ) : (
          <button
            type="button"
            key={i}
            className={"menu-item" + (it.destructive ? " destructive" : "")}
            onClick={() => {
              onClose();
              it.onSelect();
            }}
          >
            <span className="menu-check">{it.checked ? <IconCheck /> : null}</span>
            <span className="menu-label">{it.label}</span>
          </button>
        )
      )}
    </div>
  );
}

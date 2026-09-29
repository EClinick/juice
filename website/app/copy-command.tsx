"use client";

import { useEffect, useRef, useState } from "react";

function CopyIcon() {
  return (
    <svg viewBox="0 0 14 14" aria-hidden="true">
      <rect x="4.5" y="4.5" width="7.5" height="7.5" rx="1.6" fill="none" stroke="currentColor" strokeWidth="1.3" />
      <path d="M9.5 2.6V2.4A1.4 1.4 0 0 0 8.1 1H3.4A1.4 1.4 0 0 0 2 2.4v4.7a1.4 1.4 0 0 0 1.4 1.4h.2" fill="none" stroke="currentColor" strokeWidth="1.3" />
    </svg>
  );
}

function CheckIcon() {
  return (
    <svg viewBox="0 0 14 14" aria-hidden="true">
      <path d="m3 7.4 2.6 2.6L11 4.4" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

async function writeClipboard(text: string) {
  if (navigator.clipboard?.writeText) return navigator.clipboard.writeText(text);
  // Older browsers and non-secure contexts: copy through a temporary, off-screen text field.
  const field = document.createElement("textarea");
  field.value = text;
  field.setAttribute("readonly", "");
  field.style.position = "fixed";
  field.style.opacity = "0";
  document.body.append(field);
  field.select();
  const ok = document.execCommand("copy");
  field.remove();
  if (!ok) throw new Error("Copy failed");
}

export function CopyCommand({ command }: { command: string }) {
  const [copied, setCopied] = useState(false);
  const timerRef = useRef<number | undefined>(undefined);

  useEffect(() => () => window.clearTimeout(timerRef.current), []);

  const copy = async () => {
    try {
      await writeClipboard(command);
      setCopied(true);
      window.clearTimeout(timerRef.current);
      timerRef.current = window.setTimeout(() => setCopied(false), 1600);
    } catch {
      setCopied(false);
    }
  };

  return (
    <div className="command">
      <code className="command-text">
        <span aria-hidden="true">$</span>
        {command}
      </code>
      <button
        type="button"
        className={`command-copy${copied ? " is-copied" : ""}`}
        onClick={copy}
        aria-label={copied ? "Copied" : "Copy install command"}
      >
        {copied ? <CheckIcon /> : <CopyIcon />}
      </button>
      <span className="sr-only" aria-live="polite">
        {copied ? "Install command copied" : ""}
      </span>
    </div>
  );
}

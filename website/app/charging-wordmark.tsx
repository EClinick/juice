"use client";

import { animate, motion, useMotionValue, useReducedMotion } from "motion/react";
import { useCallback, useEffect, useRef, useState } from "react";

const PLUG_WIDTH = 58;
const PLUG_HEIGHT = 28;
const PLUG_BACK_X = -7;
const PLUG_TIP_X = PLUG_WIDTH - 2;
const INSERT_DEPTH = 14;
const SNAP_DISTANCE = 76;

type Point = { x: number; y: number };

export function ChargingWordmark() {
  const portRef = useRef<HTMLSpanElement>(null);
  const cableRef = useRef<SVGPathElement>(null);
  const cableHighlightRef = useRef<SVGPathElement>(null);
  const targetRef = useRef<Point>({ x: 0, y: 0 });
  const anchorRef = useRef<Point>({ x: 0, y: 0 });
  const draggingRef = useRef(false);
  const movedRef = useRef(false);
  const connectedRef = useRef(false);
  const x = useMotionValue(0);
  const y = useMotionValue(0);
  const reduceMotion = useReducedMotion();
  const [ready, setReady] = useState(false);
  const [dragging, setDragging] = useState(false);
  const [connected, setConnected] = useState(false);

  const drawCable = useCallback(() => {
    const plugX = x.get() + PLUG_BACK_X;
    const plugY = y.get() + PLUG_HEIGHT / 2;
    const anchor = anchorRef.current;
    const bendY = plugY + Math.max(54, (anchor.y - plugY) * 0.46);
    const path = `M ${anchor.x} ${anchor.y} C ${anchor.x} ${bendY}, ${plugX} ${bendY}, ${plugX} ${plugY}`;
    cableRef.current?.setAttribute("d", path);
    cableHighlightRef.current?.setAttribute("d", path);
  }, [x, y]);

  const moveHome = useCallback(
    (instant = false) => {
      const target = targetRef.current;
      const homeOffset = Math.min(118, window.innerWidth * 0.1);
      const homeX = Math.max(48, target.x - homeOffset);
      const homeLeft = homeX - PLUG_WIDTH / 2;
      const homeY = window.innerHeight - PLUG_HEIGHT - 20;
      anchorRef.current = { x: homeLeft + PLUG_BACK_X, y: window.innerHeight + 18 };
      if (instant || reduceMotion) {
        x.set(homeLeft);
        y.set(homeY);
      } else {
        animate(x, homeLeft, { type: "spring", stiffness: 350, damping: 32 });
        animate(y, homeY, { type: "spring", stiffness: 350, damping: 32 });
      }
    },
    [reduceMotion, x, y],
  );

  const snapToPort = useCallback(() => {
    const target = targetRef.current;
    connectedRef.current = true;
    setConnected(true);
    const connectedX = target.x + INSERT_DEPTH - PLUG_TIP_X;
    const connectedY = target.y - PLUG_HEIGHT / 2;
    if (reduceMotion) {
      x.set(connectedX);
      y.set(connectedY);
      return;
    }
    animate(x, connectedX, {
      type: "spring",
      stiffness: 430,
      damping: 30,
    });
    animate(y, connectedY, {
      type: "spring",
      stiffness: 430,
      damping: 30,
    });
  }, [reduceMotion, x, y]);

  const measure = useCallback(
    (preserveConnection = false) => {
      const port = portRef.current?.getBoundingClientRect();
      if (!port) return;
      targetRef.current = {
        x: port.left + port.width / 2,
        y: port.top + port.height / 2,
      };
      const homeOffset = Math.min(118, window.innerWidth * 0.1);
      const homeX = Math.max(48, targetRef.current.x - homeOffset);
      anchorRef.current = {
        x: homeX - PLUG_WIDTH / 2 + PLUG_BACK_X,
        y: window.innerHeight + 18,
      };
      if (preserveConnection && connectedRef.current) snapToPort();
      else if (!draggingRef.current) moveHome(true);
      drawCable();
      setReady(true);
    },
    [drawCable, moveHome, snapToPort],
  );

  useEffect(() => {
    let disposed = false;
    let frame = requestAnimationFrame(() => measure(false));
    const syncPosition = () => {
      if (disposed) return;
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(() => measure(true));
    };
    const resizeObserver = new ResizeObserver(syncPosition);
    const styleObserver = new MutationObserver(syncPosition);
    const port = portRef.current;
    if (port) resizeObserver.observe(port);
    if (port?.parentElement) resizeObserver.observe(port.parentElement);
    styleObserver.observe(document.head, {
      attributes: true,
      childList: true,
      characterData: true,
      subtree: true,
    });
    void document.fonts.ready.then(syncPosition);
    window.addEventListener("resize", syncPosition);
    return () => {
      disposed = true;
      cancelAnimationFrame(frame);
      resizeObserver.disconnect();
      styleObserver.disconnect();
      window.removeEventListener("resize", syncPosition);
    };
  }, [measure]);

  useEffect(() => {
    const stopX = x.on("change", drawCable);
    const stopY = y.on("change", drawCable);
    return () => {
      stopX();
      stopY();
    };
  }, [drawCable, x, y]);

  const disconnect = useCallback(() => {
    connectedRef.current = false;
    setConnected(false);
    moveHome(false);
  }, [moveHome]);

  const handleActivate = () => {
    if (movedRef.current) {
      movedRef.current = false;
      return;
    }
    if (connected) disconnect();
    else snapToPort();
  };

  return (
    <div
      className={`charging-wordmark${ready ? " is-ready" : ""}${dragging ? " is-dragging" : ""}${connected ? " is-connected" : ""}`}
    >
      <h1 id="hero-title" className="charging-title">
        JUICE
        <span ref={portRef} className="charge-port" aria-hidden="true" />
      </h1>

      <svg className="charging-cable" aria-hidden="true">
        <path ref={cableRef} className="cable-shadow" />
        <path ref={cableHighlightRef} className="cable-highlight" />
      </svg>

      <motion.button
        type="button"
        className="usb-plug"
        style={{ x, y }}
        drag
        dragMomentum={false}
        dragElastic={0}
        whileDrag={reduceMotion ? undefined : { scale: 1.045 }}
        onDragStart={() => {
          draggingRef.current = true;
          movedRef.current = false;
          setDragging(true);
          if (connected) {
            connectedRef.current = false;
            setConnected(false);
          }
        }}
        onDrag={() => {
          movedRef.current = true;
        }}
        onDragEnd={() => {
          draggingRef.current = false;
          setDragging(false);
          const target = targetRef.current;
          const connectorX = x.get() + PLUG_TIP_X;
          const connectorY = y.get() + PLUG_HEIGHT / 2;
          const distance = Math.hypot(connectorX - target.x, connectorY - target.y);
          if (distance <= SNAP_DISTANCE) snapToPort();
          else moveHome(false);
        }}
        onClick={handleActivate}
        aria-label={connected ? "Disconnect USB-C charger" : "Connect USB-C charger to the J"}
        aria-pressed={connected}
      >
        <span className="usb-collar" aria-hidden="true" />
        <span className="usb-tip" aria-hidden="true" />
        <span className="plug-instruction" aria-hidden="true">Drag to charge</span>
      </motion.button>

      <span className="sr-only" aria-live="polite">
        {connected ? "Juice is charging" : "Charger disconnected"}
      </span>
    </div>
  );
}

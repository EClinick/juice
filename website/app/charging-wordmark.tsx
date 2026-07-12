"use client";

import { animate, motion, useMotionTemplate, useMotionValue, useReducedMotion } from "motion/react";
import { useCallback, useEffect, useRef, useState } from "react";

const PLUG_WIDTH = 58;
const PLUG_HEIGHT = 28;
const PLUG_BACK_X = -7;
const PLUG_TIP_X = PLUG_WIDTH - 2;
const INSERT_DEPTH = 14;
const SNAP_DISTANCE = 76;
const HOME_SPRING = { type: "spring", stiffness: 350, damping: 32 } as const;
const CONNECT_SPRING = { type: "spring", stiffness: 430, damping: 30 } as const;

type Point = { x: number; y: number };

export function ChargingWordmark() {
  const portRef = useRef<HTMLSpanElement>(null);
  const cableRef = useRef<SVGPathElement>(null);
  const cableHighlightRef = useRef<SVGPathElement>(null);
  const guideRef = useRef<SVGPathElement>(null);
  const targetRef = useRef<Point>({ x: 0, y: 0 });
  const anchorRef = useRef<Point>({ x: 0, y: 0 });
  const draggingRef = useRef(false);
  const movedRef = useRef(false);
  const connectedRef = useRef(false);
  const pointerRef = useRef<{ id: number; offset: Point; start: Point } | null>(null);
  const x = useMotionValue(0);
  const y = useMotionValue(0);
  const dragScale = useMotionValue(1);
  const cableFlexX = useMotionValue(0);
  const cableFlexY = useMotionValue(0);
  const plugTransform = useMotionTemplate`translate3d(${x}px, ${y}px, 0) scale(${dragScale})`;
  const reduceMotion = useReducedMotion();
  const [ready, setReady] = useState(false);
  const [dragging, setDragging] = useState(false);
  const [connected, setConnected] = useState(false);

  const drawCable = useCallback(() => {
    const plugX = x.get() + PLUG_BACK_X + cableFlexX.get();
    const plugY = y.get() + PLUG_HEIGHT / 2 + cableFlexY.get();
    const anchor = anchorRef.current;
    const bendY = plugY + Math.max(54, (anchor.y - plugY) * 0.46);
    const path = `M ${anchor.x} ${anchor.y} C ${anchor.x} ${bendY}, ${plugX} ${bendY}, ${plugX} ${plugY}`;
    cableRef.current?.setAttribute("d", path);
    cableHighlightRef.current?.setAttribute("d", path);

    const target = targetRef.current;
    const guideX = x.get() + PLUG_TIP_X + cableFlexX.get() * 2;
    const guideY = y.get() + PLUG_HEIGHT / 2 + cableFlexY.get() * 2;
    const guideDistance = target.x - guideX;
    const guidePath = `M ${guideX} ${guideY} C ${guideX + guideDistance * 0.42} ${guideY}, ${target.x - guideDistance * 0.18} ${target.y}, ${target.x} ${target.y}`;
    guideRef.current?.setAttribute("d", guidePath);
  }, [cableFlexX, cableFlexY, x, y]);

  const moveHome = useCallback(
    (instant = false) => {
      const target = targetRef.current;
      const homeOffset = Math.min(118, window.innerWidth * 0.1);
      const homeX = Math.max(48, target.x - homeOffset);
      const homeLeft = homeX - PLUG_WIDTH / 2;
      const homeY = window.innerHeight - PLUG_HEIGHT - 20;
      anchorRef.current = { x: homeLeft + PLUG_BACK_X, y: window.innerHeight + 18 };
      if (instant || reduceMotion) {
        x.stop();
        y.stop();
        x.set(homeLeft);
        y.set(homeY);
      } else {
        animate(x, homeLeft, HOME_SPRING);
        animate(y, homeY, HOME_SPRING);
      }
    },
    [reduceMotion, x, y],
  );

  const positionAtPort = useCallback((instant = false) => {
    const target = targetRef.current;
    const connectedX = target.x + INSERT_DEPTH - PLUG_TIP_X;
    const connectedY = target.y - PLUG_HEIGHT / 2;
    if (instant || reduceMotion) {
      x.stop();
      y.stop();
      x.set(connectedX);
      y.set(connectedY);
      return;
    }
    animate(x, connectedX, CONNECT_SPRING);
    animate(y, connectedY, CONNECT_SPRING);
  }, [reduceMotion, x, y]);

  const snapToPort = useCallback(() => {
    connectedRef.current = true;
    setConnected(true);
    positionAtPort(false);
  }, [positionAtPort]);

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
      if (preserveConnection && connectedRef.current) positionAtPort(true);
      else if (!draggingRef.current) moveHome(true);
      drawCable();
      setReady(true);
    },
    [drawCable, moveHome, positionAtPort],
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
    window.addEventListener("scroll", syncPosition, { passive: true });
    return () => {
      disposed = true;
      cancelAnimationFrame(frame);
      resizeObserver.disconnect();
      styleObserver.disconnect();
      window.removeEventListener("resize", syncPosition);
      window.removeEventListener("scroll", syncPosition);
    };
  }, [measure]);

  useEffect(() => {
    const stopX = x.on("change", drawCable);
    const stopY = y.on("change", drawCable);
    const stopFlexX = cableFlexX.on("change", drawCable);
    const stopFlexY = cableFlexY.on("change", drawCable);
    return () => {
      stopX();
      stopY();
      stopFlexX();
      stopFlexY();
    };
  }, [cableFlexX, cableFlexY, drawCable, x, y]);

  useEffect(() => {
    cableFlexX.stop();
    cableFlexY.stop();
    cableFlexX.set(0);
    cableFlexY.set(0);

    if (!ready || dragging || connected || reduceMotion) return;

    const transition = {
      duration: 0.56,
      delay: 0.65,
      times: [0, 0.16, 0.36, 0.54, 0.7, 0.84, 0.92, 1],
      ease: [0.23, 1, 0.32, 1] as [number, number, number, number],
    };
    const flexXAnimation = animate(cableFlexX, [0, -1.5, 2, -1, 1, -0.5, 0, 0], transition);
    const flexYAnimation = animate(cableFlexY, [0, 0.5, -3.5, -2, 0, -1, 0.5, 0], transition);

    return () => {
      flexXAnimation.stop();
      flexYAnimation.stop();
    };
  }, [cableFlexX, cableFlexY, connected, dragging, ready, reduceMotion]);

  const disconnect = useCallback(() => {
    connectedRef.current = false;
    setConnected(false);
    moveHome(false);
  }, [moveHome]);

  const setPressedScale = useCallback(
    (pressed: boolean) => {
      const target = pressed ? 1.045 : 1;
      if (reduceMotion) dragScale.set(1);
      else animate(dragScale, target, { duration: 0.12, ease: [0.23, 1, 0.32, 1] });
    },
    [dragScale, reduceMotion],
  );

  const finishDrag = useCallback(() => {
    draggingRef.current = false;
    setDragging(false);
    setPressedScale(false);
    const target = targetRef.current;
    const connectorX = x.get() + PLUG_TIP_X;
    const connectorY = y.get() + PLUG_HEIGHT / 2;
    const distance = Math.hypot(connectorX - target.x, connectorY - target.y);
    if (distance <= SNAP_DISTANCE) snapToPort();
    else moveHome(false);
  }, [moveHome, setPressedScale, snapToPort, x, y]);

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
      <h1 id="hero-title" className="charging-title" data-text="JUICE">
        JUICE
        <span ref={portRef} className="charge-port" aria-hidden="true" />
      </h1>

      <svg className="charging-cable" aria-hidden="true">
        <path ref={cableRef} className="cable-shadow" />
        <path ref={cableHighlightRef} className="cable-highlight" />
        <path ref={guideRef} className="plug-guide" />
      </svg>

      <motion.button
        type="button"
        className="usb-plug"
        style={{ transform: plugTransform }}
        onPointerDown={(event) => {
          if (!event.isPrimary || event.button !== 0 || pointerRef.current) return;
          x.stop();
          y.stop();
          dragScale.stop();
          pointerRef.current = {
            id: event.pointerId,
            offset: { x: event.clientX - x.get(), y: event.clientY - y.get() },
            start: { x: event.clientX, y: event.clientY },
          };
          movedRef.current = false;
          event.currentTarget.setPointerCapture(event.pointerId);
          setPressedScale(true);
        }}
        onPointerMove={(event) => {
          const pointer = pointerRef.current;
          if (!pointer || pointer.id !== event.pointerId) return;
          const movement = Math.hypot(
            event.clientX - pointer.start.x,
            event.clientY - pointer.start.y,
          );
          if (!draggingRef.current && movement < 3) return;
          if (!draggingRef.current) {
            draggingRef.current = true;
            setDragging(true);
            if (connectedRef.current) {
              connectedRef.current = false;
              setConnected(false);
            }
          }
          movedRef.current = true;
          x.set(event.clientX - pointer.offset.x);
          y.set(event.clientY - pointer.offset.y);
        }}
        onPointerUp={(event) => {
          const pointer = pointerRef.current;
          if (!pointer || pointer.id !== event.pointerId) return;
          pointerRef.current = null;
          if (event.currentTarget.hasPointerCapture(event.pointerId)) {
            event.currentTarget.releasePointerCapture(event.pointerId);
          }
          if (draggingRef.current) finishDrag();
          else setPressedScale(false);
        }}
        onPointerCancel={(event) => {
          const pointer = pointerRef.current;
          if (!pointer || pointer.id !== event.pointerId) return;
          pointerRef.current = null;
          if (event.currentTarget.hasPointerCapture(event.pointerId)) {
            event.currentTarget.releasePointerCapture(event.pointerId);
          }
          if (draggingRef.current) finishDrag();
          else setPressedScale(false);
        }}
        onClick={handleActivate}
        aria-label={connected ? "Disconnect USB-C charger" : "Connect USB-C charger to the J"}
        aria-pressed={connected}
      >
        <span className="usb-hardware" aria-hidden="true">
          <span className="usb-collar" />
          <span className="usb-tip" />
        </span>
        <span className="plug-instruction" aria-hidden="true">Drag to charge</span>
      </motion.button>

      <span className="sr-only" aria-live="polite">
        {connected ? "Juice is charging" : "Charger disconnected"}
      </span>
    </div>
  );
}

"use client";

import { useReducedMotion } from "motion/react";
import { useEffect, useRef, useState } from "react";

const SRC = "/trailer/juice-trailer.mp4";
const POSTER = "/trailer/juice-trailer-poster.jpg";

function PlayIcon() {
  return (
    <svg viewBox="0 0 14 14" aria-hidden="true">
      <path d="M3.5 2.2v9.6a.6.6 0 0 0 .9.5l7.7-4.8a.6.6 0 0 0 0-1L4.4 1.7a.6.6 0 0 0-.9.5Z" fill="currentColor" />
    </svg>
  );
}

function PauseIcon() {
  return (
    <svg viewBox="0 0 14 14" aria-hidden="true">
      <rect x="3" y="2" width="2.8" height="10" rx=".8" fill="currentColor" />
      <rect x="8.2" y="2" width="2.8" height="10" rx=".8" fill="currentColor" />
    </svg>
  );
}

function SoundIcon({ muted }: { muted: boolean }) {
  return (
    <svg viewBox="0 0 14 14" aria-hidden="true">
      <path d="M2 5.2h2.2L7.4 2.6v8.8L4.2 8.8H2z" fill="currentColor" />
      {muted ? (
        <path d="m9.5 5.2 3 3.6m0-3.6-3 3.6" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" />
      ) : (
        <path d="M9.4 4.6a3.4 3.4 0 0 1 0 4.8m1.6-6.4a5.6 5.6 0 0 1 0 8" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" fill="none" />
      )}
    </svg>
  );
}

export function Trailer() {
  const videoRef = useRef<HTMLVideoElement>(null);
  const reduceMotion = useReducedMotion();
  const [playing, setPlaying] = useState(false);
  const [muted, setMuted] = useState(false);
  // Shown when the viewer has to start playback: reduced motion, a manual pause, or blocked autoplay
  // (for example Low Power Mode on iOS).
  const [needsTap, setNeedsTap] = useState(false);
  const userPausedRef = useRef(false);
  const userMutedRef = useRef(false);
  const heardRef = useRef(false);

  // Sound is on by default. Browsers only allow audible autoplay after the visitor has interacted with the
  // page (plugging in the charger counts), so fall back to muted autoplay when they refuse.
  const autoplay = (video: HTMLVideoElement) => {
    const playMuted = () => {
      video.muted = true;
      return video.play().catch(() => setNeedsTap(true));
    };
    const activation = (navigator as Navigator & { userActivation?: { hasBeenActive: boolean } }).userActivation;
    if (userMutedRef.current || activation?.hasBeenActive === false) {
      void playMuted();
      return;
    }
    const fromTop = video.currentTime < 0.5;
    video.muted = false;
    video
      .play()
      .then(() => {
        if (fromTop) heardRef.current = true;
      })
      .catch(() => void playMuted());
  };

  // Autoplay only while the trailer is mostly on screen, and pause it off screen:
  // a battery app should not burn battery on a video nobody is watching.
  useEffect(() => {
    const video = videoRef.current;
    if (!video) return;
    if (reduceMotion) {
      setNeedsTap(true);
      return;
    }
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (!entry.isIntersecting) video.pause();
        else if (!userPausedRef.current) autoplay(video);
      },
      { threshold: 0.5 },
    );
    observer.observe(video);
    return () => observer.disconnect();
  }, [reduceMotion]);

  const play = (withSound: boolean) => {
    const video = videoRef.current;
    if (!video) return;
    userPausedRef.current = false;
    // The first time sound comes on, start from the top so the score lines up with the picture.
    if (withSound && !heardRef.current) {
      heardRef.current = true;
      video.currentTime = 0;
    }
    if (withSound) video.muted = false;
    video.play().then(() => setNeedsTap(false)).catch(() => setNeedsTap(true));
  };

  const togglePlayback = () => {
    const video = videoRef.current;
    if (!video) return;
    if (video.paused) play(false);
    else {
      userPausedRef.current = true;
      video.pause();
    }
  };

  const toggleSound = () => {
    const video = videoRef.current;
    if (!video) return;
    if (video.muted) {
      userMutedRef.current = false;
      play(true);
    } else {
      userMutedRef.current = true;
      video.muted = true;
    }
  };

  const showStart = needsTap && !playing;

  return (
    <div className="trailer-player">
      <div className="trailer-frame">
        <video
          ref={videoRef}
          className="trailer-video"
          src={SRC}
          poster={POSTER}
          width={1920}
          height={1080}
          loop
          playsInline
          preload="none"
          aria-label="Juice product trailer"
          aria-describedby="trailer-description"
          onPlay={() => setPlaying(true)}
          onPause={() => setPlaying(false)}
          onVolumeChange={(event) => setMuted(event.currentTarget.muted)}
        />
        {showStart && (
          <button type="button" className="trailer-start" onClick={() => play(true)}>
            <span className="trailer-start-pill">
              <span className="trailer-start-icon">
                <PlayIcon />
              </span>
              Play with sound
            </span>
          </button>
        )}
      </div>

      <p id="trailer-description" className="sr-only">
        A 19-second tour of Juice. A battery drains from 100% to 23% and shrinks into the Juice icon in the menu bar.
        Clicking it opens the Juice popover, which ranks apps like Google Chrome, Cursor, and Visual Studio Code by live
        watts and energy used, then switches from this session to today. Google Chrome&apos;s detail window splits its
        energy across the CPU, GPU, and Neural Engine by hour. The popover then shows a 24-hour battery chart that leaves
        recording gaps empty and plain-English insights, and the Stats window shows the full app table and a 7-day battery
        history. Quick cards cover charge to full, Energy Mode, Mac mini server mode, electricity cost, no telemetry, and
        open source. It ends with a charger plugging into the Juice wordmark.
      </p>

      {!showStart && (
        <div className="trailer-controls">
          <button type="button" className="trailer-control" onClick={togglePlayback} aria-label={playing ? "Pause trailer" : "Play trailer"}>
            {playing ? <PauseIcon /> : <PlayIcon />}
          </button>
          <button type="button" className="trailer-control" onClick={toggleSound} aria-label={muted ? "Sound on" : "Sound off"}>
            <SoundIcon muted={muted} />
            <span className="trailer-control-label" aria-hidden="true">{muted ? "Sound on" : "Sound off"}</span>
          </button>
        </div>
      )}
    </div>
  );
}

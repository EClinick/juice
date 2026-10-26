import type { Metadata } from "next";
import { DM_Mono, Manrope } from "next/font/google";
import "./globals.css";
import shareImage from "./share-image.png";

// Self-hosted at build time. A remote CSS @import is dropped by the bundler, so these never loaded that way.
const manrope = Manrope({ subsets: ["latin"], variable: "--font-manrope", display: "swap" });
const dmMono = DM_Mono({ subsets: ["latin"], weight: ["400", "500"], variable: "--font-dm-mono", display: "swap" });

const SITE_URL = "https://getjuice.vercel.app";
const TITLE = "Juice: Know where your battery went.";
const DESCRIPTION = "Juice shows exactly what is draining your Mac battery.";
// Declared here rather than as app/opengraph-image.png: Turbopack drops that convention's .alt.txt.
const SHARE_IMAGE = {
  url: shareImage.src,
  width: shareImage.width,
  height: shareImage.height,
  alt: "The Juice wordmark filled in lime green with a USB-C cable plugged into the J, above the tagline \"Know where your battery went.\" and the Homebrew install command.",
};

// A short, silent excerpt keeps shared previews small. Keep dimensions in sync with the MP4.
const SHARE_VIDEO = {
  url: `${SITE_URL}/trailer/juice-share.mp4`,
  secureUrl: `${SITE_URL}/trailer/juice-share.mp4`,
  type: "video/mp4",
  width: 1280,
  height: 720,
};

// Next resolves images against metadataBase; video and player URLs must be absolute.
export const metadata: Metadata = {
  metadataBase: new URL(SITE_URL),
  title: TITLE,
  description: DESCRIPTION,
  openGraph: {
    type: "website",
    url: "/",
    siteName: "Juice",
    title: TITLE,
    description: DESCRIPTION,
    images: [SHARE_IMAGE],
    videos: [SHARE_VIDEO],
  },
  twitter: {
    card: "player",
    site: "@EthanClinick",
    title: TITLE,
    description: DESCRIPTION,
    images: [SHARE_IMAGE],
    players: {
      playerUrl: `${SITE_URL}/embed/juice.html`,
      streamUrl: SHARE_VIDEO.url,
      width: SHARE_VIDEO.width,
      height: SHARE_VIDEO.height,
    },
  },
  other: { "twitter:player:stream:content_type": "video/mp4" },
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en" className={`${manrope.variable} ${dmMono.variable}`}>
      <body>{children}</body>
    </html>
  );
}

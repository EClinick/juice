import type { Metadata } from "next";
import { DM_Mono, Manrope } from "next/font/google";
import "./globals.css";
import shareImage from "./share-image.png";

// Self-hosted at build time. A remote CSS @import is dropped by the bundler, so these never loaded that way.
const manrope = Manrope({ subsets: ["latin"], variable: "--font-manrope", display: "swap" });
const dmMono = DM_Mono({ subsets: ["latin"], weight: ["400", "500"], variable: "--font-dm-mono", display: "swap" });

const TITLE = "Juice: Know where your battery went.";
const DESCRIPTION = "Juice shows exactly what is draining your Mac battery.";
// Declared here rather than as app/opengraph-image.png: Turbopack drops that convention's .alt.txt.
const SHARE_IMAGE = {
  url: shareImage.src,
  width: shareImage.width,
  height: shareImage.height,
  alt: "The Juice wordmark filled in lime green with a USB-C cable plugged into the J, above the tagline \"Know where your battery went.\" and the Homebrew install command.",
};

// Link previews (Slack, iMessage, X). metadataBase makes the image URL absolute.
export const metadata: Metadata = {
  metadataBase: new URL("https://getjuice.vercel.app"),
  title: TITLE,
  description: DESCRIPTION,
  openGraph: { type: "website", url: "/", siteName: "Juice", title: TITLE, description: DESCRIPTION, images: [SHARE_IMAGE] },
  twitter: { card: "summary_large_image", title: TITLE, description: DESCRIPTION, images: [SHARE_IMAGE] },
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en" className={`${manrope.variable} ${dmMono.variable}`}>
      <body>{children}</body>
    </html>
  );
}

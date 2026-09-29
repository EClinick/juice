import type { Metadata } from "next";
import { DM_Mono, Manrope } from "next/font/google";
import "./globals.css";

// Self-hosted at build time. A remote CSS @import is dropped by the bundler, so these never loaded that way.
const manrope = Manrope({ subsets: ["latin"], variable: "--font-manrope", display: "swap" });
const dmMono = DM_Mono({ subsets: ["latin"], weight: ["400", "500"], variable: "--font-dm-mono", display: "swap" });

export const metadata: Metadata = {
  title: "Juice: Know where your battery went.",
  description: "Juice shows exactly what is draining your Mac battery.",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en" className={`${manrope.variable} ${dmMono.variable}`}>
      <body>{children}</body>
    </html>
  );
}

import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Juice: Know where your battery went.",
  description: "Juice shows exactly what is draining your Mac battery.",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}

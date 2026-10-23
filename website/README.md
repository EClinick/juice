# Juice landing page

The landing page is a Next.js app. From this directory, install dependencies and start the local preview:

```bash
npm install
npm run dev
```

Open [http://localhost:3000](http://localhost:3000). Run `npm run build` to verify the production build.

## Link previews

The root layout publishes Open Graph video metadata and an X player card for
`https://getjuice.vercel.app`. The preview is the first 12 seconds of the existing
trailer, encoded as a silent 1280×720 H.264 MP4 at 30 fps with fast start. The
existing share image remains the fallback for clients that only show images.
`public/embed/juice.html` is the standalone, iframe-compatible player for X.
Whether a client shows a playable video depends on its support and cached cards.

Regenerate the snippet from the website directory with:

```bash
ffmpeg -i public/trailer/juice-trailer.mp4 -t 12 -map 0:v:0 \
  -vf 'scale=1280:720,fps=30' -c:v libx264 -preset slow -crf 24 \
  -pix_fmt yuv420p -an -movflags +faststart public/trailer/juice-share.mp4
```

After building, check that `/` includes absolute HTTPS `og:video`,
`og:video:secure_url`, MIME type and dimensions, plus `twitter:card=player` and
`twitter:player`. Verify the MP4 and `/embed/juice.html` are publicly reachable
and that byte-range requests to the MP4 return `206 Partial Content`.
